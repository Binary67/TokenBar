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

    func testMapsFiveHourAndWeeklyLimitsByDuration() async throws {
        let now = Date()
        let fiveHourReset = now.addingTimeInterval(60 * 60)
        let weeklyReset = now.addingTimeInterval(4 * 24 * 60 * 60)
        let home = try makeCodexHome(records: [
            tokenRecord(
                at: now,
                tokens: 500,
                rateLimits: [
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

        let snapshot = await firstSnapshot(from: CodexMonitor(codexHome: home))
        let fiveHourLimit = try XCTUnwrap(snapshot.fiveHourLimit)
        let weeklyLimit = try XCTUnwrap(snapshot.weeklyLimit)

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

    func testCountsOnlyCurrentLocalDayAndReportsWorking() async throws {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: dayStart))
        let home = try makeCodexHome(records: [
            tokenRecord(at: dayStart.addingTimeInterval(-1), tokens: 900),
            Data("not json\n".utf8),
            tokenRecord(at: dayStart.addingTimeInterval(60), tokens: 1_234),
            tokenRecord(at: tomorrow.addingTimeInterval(1), tokens: 8_000),
            taskRecord(type: "task_started", turnID: "turn-1", at: now),
        ])

        let snapshot = await firstSnapshot(from: CodexMonitor(codexHome: home))

        XCTAssertEqual(snapshot.todayTokens, 1_234)
        XCTAssertEqual(snapshot.status, .working)
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

        let interrupted = await firstSnapshot(from: CodexMonitor(codexHome: interruptedHome))
        let failed = await firstSnapshot(from: CodexMonitor(codexHome: failedHome))

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

        let snapshot = await firstSnapshot(from: CodexMonitor(codexHome: home))

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

        let snapshot = await firstSnapshot(from: CodexMonitor(codexHome: home))

        XCTAssertEqual(snapshot.status, .idle)
    }

    func testPartialLineAndRepeatedPollingDoNotDoubleCount() async throws {
        let home = try makeCodexHome(records: [])
        let rolloutURL = home.appendingPathComponent("sessions/rollout.jsonl")
        let record = tokenRecord(at: Date(), tokens: 500, includesNewline: false)
        try record.write(to: rolloutURL)

        let monitor = CodexMonitor(codexHome: home, pollInterval: .milliseconds(20))
        let initial = expectation(description: "Initial partial line is ignored")
        let updated = expectation(description: "Completed line remains counted once")
        updated.expectedFulfillmentCount = 2
        var sawInitial = false
        var updatedValues = [Int64]()

        let task = Task {
            await monitor.run { snapshot in
                if !sawInitial, snapshot.todayTokens == 0 {
                    sawInitial = true
                    initial.fulfill()
                } else if sawInitial, snapshot.todayTokens == 500, updatedValues.count < 2 {
                    updatedValues.append(snapshot.todayTokens)
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
    }

    func testReplacingSessionFileRebuildsItsSubtotal() async throws {
        let home = try makeCodexHome(records: [tokenRecord(at: Date(), tokens: 100)])
        let rolloutURL = home.appendingPathComponent("sessions/rollout.jsonl")
        let monitor = CodexMonitor(codexHome: home, pollInterval: .milliseconds(20))
        let initial = expectation(description: "Initial total")
        let replaced = expectation(description: "Replacement total")
        var didReplace = false

        let task = Task {
            await monitor.run { snapshot in
                if snapshot.todayTokens == 100, !didReplace {
                    didReplace = true
                    initial.fulfill()
                } else if snapshot.todayTokens == 250 {
                    replaced.fulfill()
                }
            }
        }

        await fulfillment(of: [initial], timeout: 2)
        try tokenRecord(at: Date(), tokens: 250).write(to: rolloutURL, options: .atomic)
        await fulfillment(of: [replaced], timeout: 2)
        task.cancel()
    }

    func testMissingCodexStorageIsUnavailable() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let snapshot = await firstSnapshot(from: CodexMonitor(codexHome: home))

        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertEqual(snapshot.todayTokens, 0)
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
        var payload: [String: Any] = [
            "type": "token_count",
            "info": [
                "last_token_usage": [
                    "input_tokens": tokens - 10,
                    "cached_input_tokens": tokens - 20,
                    "output_tokens": 10,
                    "reasoning_output_tokens": 5,
                    "total_tokens": tokens,
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
