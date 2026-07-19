import Foundation
import SQLite3
import XCTest
@testable import TokenBar

@MainActor
final class CodexMonitorTests: XCTestCase {
    func testCompactAndExactFormatting() {
        XCTAssertEqual(TokenTextFormatter.compact(999), "999")
        XCTAssertEqual(TokenTextFormatter.compact(1_200), "1.2K")
        XCTAssertEqual(TokenTextFormatter.compact(842_000), "842K")
        XCTAssertEqual(TokenTextFormatter.compact(1_240_000), "1.24M")
        XCTAssertEqual(TokenTextFormatter.compact(12_400_000), "12.4M")
        XCTAssertEqual(TokenTextFormatter.compact(128_000_000), "128M")
        XCTAssertEqual(TokenTextFormatter.exact(12_438_219), "12,438,219")
    }

    func testPercentLeftIsClampedAndRounded() {
        XCTAssertEqual(CodexRateLimitWindow(usedPercent: 17.4, resetsAt: nil).percentLeft, 83)
        XCTAssertEqual(CodexRateLimitWindow(usedPercent: -1, resetsAt: nil).percentLeft, 100)
        XCTAssertEqual(CodexRateLimitWindow(usedPercent: 101, resetsAt: nil).percentLeft, 0)
    }

    func testMapsProSubscriptionPlansAndCalculatesValueMetrics() throws {
        let pro5x = try XCTUnwrap(CodexSubscriptionPlan(planType: "prolite"))
        let pro20x = try XCTUnwrap(CodexSubscriptionPlan(planType: "pro"))

        XCTAssertEqual(pro5x, .pro5x)
        XCTAssertEqual(pro5x.label, "Pro 5×")
        XCTAssertEqual(pro5x.monthlyPriceUSD, 100)
        XCTAssertEqual(pro20x, .pro20x)
        XCTAssertEqual(pro20x.label, "Pro 20×")
        XCTAssertEqual(pro20x.monthlyPriceUSD, 200)
        XCTAssertNil(CodexSubscriptionPlan(planType: "plus"))

        let pro5xSnapshot = TokenBarSnapshot(
            status: .idle,
            todayTokens: 0,
            lastUpdated: .now,
            last30DaysAPICostUSD: 380,
            subscriptionPlan: pro5x
        )
        let pro20xSnapshot = TokenBarSnapshot(
            status: .idle,
            todayTokens: 0,
            lastUpdated: .now,
            last30DaysAPICostUSD: 380,
            subscriptionPlan: pro20x
        )

        XCTAssertEqual(pro5xSnapshot.subscriptionValueMultiple, 3.8)
        XCTAssertEqual(pro20xSnapshot.subscriptionValueMultiple, 1.9)
        XCTAssertEqual(pro5xSnapshot.estimatedBreakEvenDays, 8)
        XCTAssertEqual(pro20xSnapshot.estimatedBreakEvenDays, 16)

        let estimatedSeventeenDaySnapshot = TokenBarSnapshot(
            status: .idle,
            todayTokens: 0,
            lastUpdated: .now,
            last30DaysAPICostUSD: 174.32,
            subscriptionPlan: pro5x
        )
        XCTAssertEqual(estimatedSeventeenDaySnapshot.estimatedBreakEvenDays, 17)

        let inactiveSnapshot = TokenBarSnapshot(
            status: .idle,
            todayTokens: 0,
            lastUpdated: .now,
            last30DaysAPICostUSD: 0,
            subscriptionPlan: pro5x
        )
        XCTAssertNil(inactiveSnapshot.estimatedBreakEvenDays)
    }

    func testCalculatesStandardAPIEquivalentCostForSupportedModels() async throws {
        let cases = [
            (model: "gpt-5.6-sol", expectedCost: 0.005725),
            (model: "gpt-5.6-terra", expectedCost: 0.0028625),
            (model: "gpt-5.6-luna", expectedCost: 0.001145),
        ]

        for testCase in cases {
            let now = Date()
            let home = try makeCodexHome(records: [
                modelRecord(testCase.model, at: now),
                tokenRecord(
                    at: now.addingTimeInterval(1),
                    inputTokens: 1_000,
                    cachedInputTokens: 200,
                    cacheWriteInputTokens: 100,
                    outputTokens: 50,
                    reasoningOutputTokens: 40
                ),
            ])

            let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

            XCTAssertEqual(snapshot.todayTokens, 1_050)
            XCTAssertEqual(snapshot.trackedTodayTokens, 1_050)
            XCTAssertEqual(snapshot.last30DaysTokens, 1_050)
            XCTAssertEqual(snapshot.dailyUsage.count, 30)
            XCTAssertEqual(try apiCost(from: snapshot), testCase.expectedCost, accuracy: 0.000_000_001)
        }
    }

    func testBuildsThirtyLocalDayModelHistory() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let thirtyDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: today))
        let twentyNineDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -29, to: today))
        let fifteenDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -15, to: today))
        let home = try makeCodexHome(records: [
            modelRecord("gpt-5.6-sol", at: thirtyDaysAgo),
            tokenRecord(
                at: thirtyDaysAgo.addingTimeInterval(1),
                inputTokens: 400,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0
            ),
            modelRecord("gpt-5.6-sol", at: twentyNineDaysAgo),
            tokenRecord(
                at: twentyNineDaysAgo.addingTimeInterval(1),
                inputTokens: 100,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0
            ),
            modelRecord("gpt-5.6-terra", at: fifteenDaysAgo),
            tokenRecord(
                at: fifteenDaysAgo.addingTimeInterval(1),
                inputTokens: 200,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0
            ),
            modelRecord("gpt-5.6-luna", at: today),
            tokenRecord(
                at: today.addingTimeInterval(1),
                inputTokens: 300,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0
            ),
        ])

        let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

        XCTAssertEqual(snapshot.todayTokens, 300)
        XCTAssertEqual(snapshot.trackedTodayTokens, 300)
        XCTAssertEqual(snapshot.last30DaysTokens, 600)
        XCTAssertEqual(snapshot.dailyUsage.count, 30)
        XCTAssertEqual(snapshot.dailyUsage.first?.day, twentyNineDaysAgo)
        XCTAssertEqual(snapshot.dailyUsage.first?.sol.tokens, 100)
        XCTAssertEqual(snapshot.dailyUsage[14].terra.tokens, 200)
        XCTAssertEqual(snapshot.dailyUsage.last?.luna.tokens, 300)
        XCTAssertEqual(
            NSDecimalNumber(decimal: try XCTUnwrap(snapshot.last30DaysAPICostUSD)).doubleValue,
            0.0013,
            accuracy: 0.000_000_001
        )
    }

    func testAppliesModelChangesWithinOneSession() async throws {
        let now = Date()
        let home = try makeCodexHome(records: [
            modelRecord("gpt-5.6-sol", at: now),
            tokenRecord(
                at: now.addingTimeInterval(1),
                inputTokens: 100,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0
            ),
            modelRecord("gpt-5.6-luna", at: now.addingTimeInterval(2)),
            tokenRecord(
                at: now.addingTimeInterval(3),
                inputTokens: 100,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0
            ),
        ])

        let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

        XCTAssertEqual(snapshot.todayTokens, 200)
        XCTAssertEqual(try apiCost(from: snapshot), 0.0006, accuracy: 0.000_000_001)
    }

    func testMissingOrUnsupportedModelsAreExcludedFromTrackedUsage() async throws {
        let now = Date()
        let usage = tokenRecord(
            at: now.addingTimeInterval(1),
            inputTokens: 100,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 10
        )
        let recordSets = [
            [usage],
            [modelRecord("gpt-5.5", at: now), usage],
        ]

        for records in recordSets {
            let home = try makeCodexHome(records: records)
            let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

            XCTAssertEqual(snapshot.todayTokens, 110)
            XCTAssertEqual(snapshot.trackedTodayTokens, 0)
            XCTAssertEqual(try apiCost(from: snapshot), 0, accuracy: 0.000_000_001)
        }
    }

    func testExcludesAutoReviewUsageFromCost() async throws {
        let now = Date()
        let home = try makeCodexHome(records: [
            modelRecord("gpt-5.6-sol", at: now),
            tokenRecord(
                at: now.addingTimeInterval(1),
                inputTokens: 100,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0
            ),
            modelRecord("codex-auto-review", at: now.addingTimeInterval(2)),
            tokenRecord(
                at: now.addingTimeInterval(3),
                inputTokens: 1_000,
                cachedInputTokens: 200,
                cacheWriteInputTokens: 100,
                outputTokens: 50
            ),
        ])

        let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

        XCTAssertEqual(snapshot.todayTokens, 1_150)
        XCTAssertEqual(snapshot.trackedTodayTokens, 100)
        XCTAssertEqual(snapshot.last30DaysTokens, 100)
        XCTAssertEqual(try apiCost(from: snapshot), 0.0005, accuracy: 0.000_000_001)
    }

    func testMapsFiveHourAndWeeklyLimitsByDuration() async throws {
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(60 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        let home = try makeCodexHome(records: [
            tokenRecord(
                at: now,
                tokens: 500,
                rateLimits: [
                    "plan_type": "prolite",
                    "primary": rateLimitWindow(
                        usedPercent: 64,
                        resetsAt: weeklyReset,
                        windowMinutes: 10_080
                    ),
                    "secondary": rateLimitWindow(
                        usedPercent: 18,
                        resetsAt: fiveHourReset,
                        windowMinutes: 300
                    ),
                ]
            ),
        ])

        let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))
        let fiveHourLimit = try XCTUnwrap(snapshot.fiveHourLimit)
        let weeklyLimit = try XCTUnwrap(snapshot.weeklyLimit)

        XCTAssertEqual(snapshot.subscriptionPlan, .pro5x)
        XCTAssertEqual(fiveHourLimit.percentLeft, 82)
        XCTAssertEqual(
            try XCTUnwrap(fiveHourLimit.resetsAt).timeIntervalSince1970,
            fiveHourReset.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(weeklyLimit.percentLeft, 36)
        XCTAssertEqual(
            try XCTUnwrap(weeklyLimit.resetsAt).timeIntervalSince1970,
            weeklyReset.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    func testLatestReportedSubscriptionPlanWins() async throws {
        let now = Date()
        let home = try makeCodexHome(records: [
            tokenRecord(
                at: now,
                tokens: 100,
                rateLimits: ["plan_type": "prolite"]
            ),
            tokenRecord(
                at: now.addingTimeInterval(1),
                tokens: 100,
                rateLimits: ["plan_type": "pro"]
            ),
        ])

        let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

        XCTAssertEqual(snapshot.subscriptionPlan, .pro20x)
    }

    func testCountsOnlyCurrentLocalDayAndReportsWorking() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let home = try makeCodexHome(records: [
            modelRecord("gpt-5.6-sol", at: dayStart.addingTimeInterval(-2)),
            tokenRecord(at: dayStart.addingTimeInterval(-1), tokens: 900),
            Data("not json\n".utf8),
            tokenRecord(at: dayStart.addingTimeInterval(60), tokens: 1_234),
            tokenRecord(at: tomorrow.addingTimeInterval(1), tokens: 8_000),
            taskRecord(type: "task_started", turnID: "turn-1", at: now),
        ])

        let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

        XCTAssertEqual(snapshot.todayTokens, 1_234)
        XCTAssertEqual(snapshot.status, .working)
        XCTAssertEqual(try apiCost(from: snapshot), 0.000957, accuracy: 0.000_000_001)
    }

    func testInterruptedTurnIsIdleAndFailedTurnIsError() async throws {
        let now = Date()
        let interruptedHome = try makeCodexHome(records: [
            taskRecord(type: "task_started", turnID: "turn-1", at: now),
            taskRecord(
                type: "turn_aborted",
                turnID: "turn-1",
                at: now.addingTimeInterval(1),
                reason: "interrupted"
            ),
        ])
        let failedHome = try makeCodexHome(records: [
            taskRecord(type: "task_started", turnID: "turn-2", at: now),
            taskRecord(
                type: "turn_aborted",
                turnID: "turn-2",
                at: now.addingTimeInterval(1),
                reason: "failed"
            ),
        ])

        let interrupted = await firstSnapshot(from: makeMonitor(codexHome: interruptedHome))
        let failed = await firstSnapshot(from: makeMonitor(codexHome: failedHome))

        XCTAssertEqual(interrupted.status, .idle)
        XCTAssertEqual(failed.status, .error)
    }

    func testLatestTerminalEventAcrossSessionsDeterminesStatus() async throws {
        let now = Date()
        let home = try makeCodexHome(
            records: [
                taskRecord(type: "task_started", turnID: "failed-turn", at: now.addingTimeInterval(-4)),
                taskRecord(
                    type: "turn_aborted",
                    turnID: "failed-turn",
                    at: now.addingTimeInterval(-3),
                    reason: "failed"
                ),
            ],
            additionalSessions: [[
                taskRecord(type: "task_started", turnID: "completed-turn", at: now.addingTimeInterval(-2)),
                taskRecord(type: "task_complete", turnID: "completed-turn", at: now.addingTimeInterval(-1)),
            ]]
        )

        let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

        XCTAssertEqual(snapshot.status, .idle)
    }

    func testStaleUnmatchedTaskIsIgnoredOnColdLaunch() async throws {
        let now = Date()
        let home = try makeCodexHome(records: [
            taskRecord(type: "task_started", turnID: "stale-turn", at: now.addingTimeInterval(-3_600)),
        ])
        let rolloutURL = home.appendingPathComponent("sessions/rollout.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-31 * 60)],
            ofItemAtPath: rolloutURL.path
        )

        let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

        XCTAssertEqual(snapshot.status, .idle)
    }

    func testPartialLineAndRepeatedPollingDoNotDoubleCount() async throws {
        let home = try makeCodexHome(records: [modelRecord("gpt-5.6-sol", at: Date())])
        let rolloutURL = home.appendingPathComponent("sessions/rollout.jsonl")
        let record = tokenRecord(at: Date(), tokens: 500, includesNewline: false)
        let recordHandle = try FileHandle(forWritingTo: rolloutURL)
        try recordHandle.seekToEnd()
        try recordHandle.write(contentsOf: record)
        try recordHandle.close()

        let monitor = makeMonitor(codexHome: home, pollInterval: .milliseconds(20))
        let initial = expectation(description: "Initial partial line is ignored")
        let updated = expectation(description: "Completed line remains counted once")
        updated.expectedFulfillmentCount = 2
        var sawInitial = false
        var updatedValues = [Int64]()
        var updatedHistoryValues = [Int64]()
        var updatedCosts = [Decimal]()

        let task = Task {
            await monitor.run { snapshot in
                if !sawInitial, snapshot.todayTokens == 0 {
                    sawInitial = true
                    initial.fulfill()
                } else if sawInitial,
                          snapshot.todayTokens == 500,
                          let cost = snapshot.estimatedAPICostUSD,
                          updatedValues.count < 2 {
                    updatedValues.append(snapshot.todayTokens)
                    updatedHistoryValues.append(snapshot.last30DaysTokens)
                    updatedCosts.append(cost)
                    updated.fulfill()
                }
            }
        }

        await fulfillment(of: [initial], timeout: 2)
        let handle = try FileHandle(forWritingTo: rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        await fulfillment(of: [updated], timeout: 2)
        task.cancel()

        XCTAssertEqual(updatedValues, [500, 500])
        XCTAssertEqual(updatedHistoryValues, [500, 500])
        XCTAssertEqual(
            updatedCosts.map { NSDecimalNumber(decimal: $0).doubleValue },
            [0.00059, 0.00059]
        )
    }

    func testReplacingSessionFileRebuildsItsSubtotal() async throws {
        let now = Date()
        let home = try makeCodexHome(records: [
            modelRecord("gpt-5.6-sol", at: now),
            tokenRecord(at: now.addingTimeInterval(1), tokens: 100),
        ])
        let rolloutURL = home.appendingPathComponent("sessions/rollout.jsonl")
        let monitor = makeMonitor(codexHome: home, pollInterval: .milliseconds(20))
        let initial = expectation(description: "Initial total")
        let replaced = expectation(description: "Replacement total")
        var didReplace = false
        var sawReplacement = false
        var initialCost: Decimal?
        var replacementCost: Decimal?
        var initialHistoryTokens: Int64?
        var replacementHistoryTokens: Int64?

        let task = Task {
            await monitor.run { snapshot in
                if snapshot.todayTokens == 100, !didReplace {
                    didReplace = true
                    initialCost = snapshot.estimatedAPICostUSD
                    initialHistoryTokens = snapshot.last30DaysTokens
                    initial.fulfill()
                } else if snapshot.todayTokens == 250, !sawReplacement {
                    sawReplacement = true
                    replacementCost = snapshot.estimatedAPICostUSD
                    replacementHistoryTokens = snapshot.last30DaysTokens
                    replaced.fulfill()
                }
            }
        }

        await fulfillment(of: [initial], timeout: 2)
        var replacement = modelRecord("gpt-5.6-sol", at: Date())
        replacement.append(tokenRecord(at: Date().addingTimeInterval(1), tokens: 250))
        try replacement.write(to: rolloutURL, options: .atomic)
        await fulfillment(of: [replaced], timeout: 2)
        task.cancel()

        XCTAssertEqual(
            NSDecimalNumber(decimal: try XCTUnwrap(initialCost)).doubleValue,
            0.00039,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            NSDecimalNumber(decimal: try XCTUnwrap(replacementCost)).doubleValue,
            0.000465,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(initialHistoryTokens, 100)
        XCTAssertEqual(replacementHistoryTokens, 250)
    }

    func testCacheReloadContinuesFromPersistedModelAndOffset() async throws {
        let now = Date()
        let home = try makeCodexHome(records: [
            modelRecord("gpt-5.6-sol", at: now),
            tokenRecord(
                at: now.addingTimeInterval(1),
                tokens: 100,
                rateLimits: ["plan_type": "prolite"]
            ),
        ])
        let rolloutURL = home.appendingPathComponent("sessions/rollout.jsonl")

        let initial = await firstSnapshot(from: makeMonitor(codexHome: home))

        let handle = try FileHandle(forWritingTo: rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: tokenRecord(at: now.addingTimeInterval(2), tokens: 200))
        try handle.close()

        let updated = await firstSnapshot(from: makeMonitor(codexHome: home))
        let unchanged = await firstSnapshot(from: makeMonitor(codexHome: home))

        XCTAssertEqual(initial.trackedTodayTokens, 100)
        XCTAssertEqual(updated.trackedTodayTokens, 300)
        XCTAssertEqual(unchanged.trackedTodayTokens, 300)
        XCTAssertEqual(initial.subscriptionPlan, .pro5x)
        XCTAssertEqual(updated.subscriptionPlan, .pro5x)
        XCTAssertEqual(unchanged.subscriptionPlan, .pro5x)
        XCTAssertEqual(try apiCost(from: updated), 0.00083, accuracy: 0.000_000_001)
        XCTAssertEqual(try apiCost(from: unchanged), 0.00083, accuracy: 0.000_000_001)
    }

    func testMissingCodexStorageIsUnavailable() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let snapshot = await firstSnapshot(from: makeMonitor(codexHome: home))

        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertEqual(snapshot.todayTokens, 0)
        XCTAssertNil(snapshot.estimatedAPICostUSD)
    }

    private func apiCost(from snapshot: TokenBarSnapshot) throws -> Double {
        NSDecimalNumber(decimal: try XCTUnwrap(snapshot.estimatedAPICostUSD)).doubleValue
    }

    private func makeMonitor(
        codexHome: URL,
        pollInterval: Duration = .seconds(2)
    ) -> CodexMonitor {
        CodexMonitor(
            codexHome: codexHome,
            pollInterval: pollInterval,
            cacheURL: codexHome.appendingPathComponent("usage-history.json")
        )
    }

    private func firstSnapshot(from monitor: CodexMonitor) async -> TokenBarSnapshot {
        let received = expectation(description: "Snapshot received")
        var result: TokenBarSnapshot?
        let task = Task {
            await monitor.run { snapshot in
                guard result == nil else { return }
                result = snapshot
                received.fulfill()
            }
        }

        await fulfillment(of: [received], timeout: 2)
        task.cancel()
        return result ?? TokenBarSnapshot(status: .unavailable, todayTokens: 0, lastUpdated: .now)
    }

    private func makeCodexHome(
        records: [Data],
        additionalSessions: [[Data]] = []
    ) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let rolloutURL = sessions.appendingPathComponent("rollout.jsonl")
        let allSessions = [records] + additionalSessions
        let rolloutURLs = try allSessions.enumerated().map { index, sessionRecords in
            let url = index == 0
                ? rolloutURL
                : sessions.appendingPathComponent("rollout-\(index).jsonl")
            var contents = Data()
            for record in sessionRecords {
                contents.append(record)
            }
            try contents.write(to: url)
            return url
        }

        let databaseURL = home.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { throw FixtureError.database }
        defer { sqlite3_close(database) }

        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE threads (rollout_path TEXT NOT NULL, updated_at_ms INTEGER NOT NULL)",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "INSERT INTO threads (rollout_path, updated_at_ms) VALUES (?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        guard let statement else { throw FixtureError.database }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for url in rolloutURLs {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, url.path, -1, transient)
            sqlite3_bind_int64(statement, 2, Int64(Date().timeIntervalSince1970 * 1_000))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }

        return home
    }

    private func tokenRecord(
        at date: Date,
        tokens: Int64,
        rateLimits: [String: Any]? = nil,
        includesNewline: Bool = true
    ) -> Data {
        tokenRecord(
            at: date,
            inputTokens: tokens - 10,
            cachedInputTokens: tokens - 20,
            cacheWriteInputTokens: 0,
            outputTokens: 10,
            reasoningOutputTokens: 5,
            rateLimits: rateLimits,
            includesNewline: includesNewline
        )
    }

    private func tokenRecord(
        at date: Date,
        inputTokens: Int64,
        cachedInputTokens: Int64,
        cacheWriteInputTokens: Int64,
        outputTokens: Int64,
        reasoningOutputTokens: Int64 = 0,
        rateLimits: [String: Any]? = nil,
        includesNewline: Bool = true
    ) -> Data {
        var payload: [String: Any] = [
            "type": "token_count",
            "info": [
                "last_token_usage": [
                    "input_tokens": inputTokens,
                    "cached_input_tokens": cachedInputTokens,
                    "cache_write_input_tokens": cacheWriteInputTokens,
                    "output_tokens": outputTokens,
                    "reasoning_output_tokens": reasoningOutputTokens,
                    "total_tokens": inputTokens + outputTokens,
                ],
            ],
        ]
        if let rateLimits {
            payload["rate_limits"] = rateLimits
        }

        return jsonLine(
            [
                "timestamp": timestamp(date),
                "type": "event_msg",
                "payload": payload,
            ],
            includesNewline: includesNewline
        )
    }

    private func modelRecord(_ model: String, at date: Date) -> Data {
        jsonLine([
            "timestamp": timestamp(date),
            "type": "turn_context",
            "payload": ["model": model],
        ])
    }

    private func rateLimitWindow(
        usedPercent: Double,
        resetsAt: Date,
        windowMinutes: Int64
    ) -> [String: Any] {
        [
            "used_percent": usedPercent,
            "resets_at": resetsAt.timeIntervalSince1970,
            "window_minutes": windowMinutes,
        ]
    }

    private func taskRecord(
        type: String,
        turnID: String,
        at date: Date,
        reason: String? = nil
    ) -> Data {
        var payload: [String: Any] = [
            "type": type,
            "turn_id": turnID,
        ]
        if let reason {
            payload["reason"] = reason
        }
        return jsonLine([
            "timestamp": timestamp(date),
            "type": "event_msg",
            "payload": payload,
        ])
    }

    private func jsonLine(_ object: [String: Any], includesNewline: Bool = true) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if includesNewline {
            data.append(0x0A)
        }
        return data
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private enum FixtureError: Error {
        case database
    }
}
