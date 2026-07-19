//
//  CodexMonitor.swift
//  TokenBar
//

import Foundation
import SQLite3

enum CodexStatus: String, Sendable {
    case working
    case idle
    case error
    case unavailable

    nonisolated var label: String {
        rawValue.capitalized
    }

    var symbolName: String {
        switch self {
        case .working:
            "arrow.triangle.2.circlepath"
        case .idle:
            "circle"
        case .error:
            "exclamationmark.circle.fill"
        case .unavailable:
            "questionmark.circle"
        }
    }
}

struct TokenBarSnapshot: Equatable, Sendable {
    let status: CodexStatus
    let todayTokens: Int64
    let lastUpdated: Date
    var fiveHourLimit: CodexRateLimitWindow? = nil
    var weeklyLimit: CodexRateLimitWindow? = nil
    var estimatedAPICostUSD: Decimal? = nil
    var trackedTodayTokens: Int64 = 0
    var last30DaysTokens: Int64 = 0
    var last30DaysAPICostUSD: Decimal? = nil
    var dailyUsage: [CodexDailyUsage] = []
    var subscriptionPlan: CodexSubscriptionPlan? = nil

    var subscriptionValueMultiple: Decimal? {
        guard let last30DaysAPICostUSD, let subscriptionPlan else { return nil }
        return last30DaysAPICostUSD / subscriptionPlan.monthlyPriceUSD
    }

    var estimatedBreakEvenDays: Int? {
        guard let last30DaysAPICostUSD,
              last30DaysAPICostUSD > 0,
              let firstUsageIndex = dailyUsage.firstIndex(where: {
                  $0.estimatedAPICostUSD > 0
              }),
              let subscriptionPlan else {
            return nil
        }

        let observedDays = dailyUsage.count - firstUsageIndex
        var estimate = subscriptionPlan.monthlyPriceUSD
            * Decimal(observedDays)
            / last30DaysAPICostUSD
        var roundedEstimate = Decimal.zero
        NSDecimalRound(&roundedEstimate, &estimate, 0, .up)
        return max(1, NSDecimalNumber(decimal: roundedEstimate).intValue)
    }
}

enum CodexSubscriptionPlan: Equatable, Sendable {
    case pro5x
    case pro20x

    init?(planType: String) {
        switch planType {
        case "prolite":
            self = .pro5x
        case "pro":
            self = .pro20x
        default:
            return nil
        }
    }

    var label: String {
        switch self {
        case .pro5x:
            "Pro 5×"
        case .pro20x:
            "Pro 20×"
        }
    }

    var monthlyPriceUSD: Decimal {
        switch self {
        case .pro5x:
            100
        case .pro20x:
            200
        }
    }
}

enum CodexTrackedModel: String, CaseIterable, Codable, Sendable {
    case sol = "gpt-5.6-sol"
    case terra = "gpt-5.6-terra"
    case luna = "gpt-5.6-luna"

    var label: String {
        rawValue
            .replacingOccurrences(of: "gpt-5.6-", with: "")
            .capitalized
    }
}

struct CodexModelUsage: Codable, Equatable, Sendable {
    var tokens: Int64 = 0
    var estimatedAPICostUSD = Decimal.zero
}

struct CodexDailyUsage: Codable, Equatable, Identifiable, Sendable {
    let day: Date
    var sol = CodexModelUsage()
    var terra = CodexModelUsage()
    var luna = CodexModelUsage()

    nonisolated var id: Date { day }

    nonisolated var totalTokens: Int64 {
        sol.tokens + terra.tokens + luna.tokens
    }

    nonisolated var estimatedAPICostUSD: Decimal {
        sol.estimatedAPICostUSD
            + terra.estimatedAPICostUSD
            + luna.estimatedAPICostUSD
    }

    nonisolated func usage(for model: CodexTrackedModel) -> CodexModelUsage {
        switch model {
        case .sol:
            sol
        case .terra:
            terra
        case .luna:
            luna
        }
    }

    nonisolated mutating func add(
        tokens: Int64,
        cost: Decimal,
        for model: CodexTrackedModel
    ) {
        switch model {
        case .sol:
            sol.tokens += tokens
            sol.estimatedAPICostUSD += cost
        case .terra:
            terra.tokens += tokens
            terra.estimatedAPICostUSD += cost
        case .luna:
            luna.tokens += tokens
            luna.estimatedAPICostUSD += cost
        }
    }

    nonisolated mutating func add(_ usage: CodexDailyUsage) {
        sol.tokens += usage.sol.tokens
        sol.estimatedAPICostUSD += usage.sol.estimatedAPICostUSD
        terra.tokens += usage.terra.tokens
        terra.estimatedAPICostUSD += usage.terra.estimatedAPICostUSD
        luna.tokens += usage.luna.tokens
        luna.estimatedAPICostUSD += usage.luna.estimatedAPICostUSD
    }
}

struct CodexRateLimitWindow: Equatable, Sendable {
    let usedPercent: Double
    let resetsAt: Date?

    var percentLeft: Int {
        Int(max(0, min(100, 100 - usedPercent)).rounded())
    }
}

enum TokenTextFormatter {
    nonisolated static func compact(_ tokens: Int64) -> String {
        switch tokens {
        case ..<1_000:
            return String(tokens)
        case ..<10_000:
            return scaled(tokens, divisor: 1_000, decimals: 1, suffix: "K")
        case ..<1_000_000:
            return scaled(tokens, divisor: 1_000, decimals: 0, suffix: "K")
        case ..<10_000_000:
            return scaled(tokens, divisor: 1_000_000, decimals: 2, suffix: "M")
        case ..<100_000_000:
            return scaled(tokens, divisor: 1_000_000, decimals: 1, suffix: "M")
        default:
            return scaled(tokens, divisor: 1_000_000, decimals: 0, suffix: "M")
        }
    }

    nonisolated static func exact(_ tokens: Int64) -> String {
        let digits = String(tokens)
        var grouped = ""
        grouped.reserveCapacity(digits.count + digits.count / 3)

        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index.isMultiple(of: 3) {
                grouped.append(",")
            }
            grouped.append(character)
        }

        return String(grouped.reversed())
    }

    nonisolated private static func scaled(
        _ tokens: Int64,
        divisor: Double,
        decimals: Int,
        suffix: String
    ) -> String {
        let value = Double(tokens) / divisor
        let number = value.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .precision(.fractionLength(decimals))
        )
        return "\(number)\(suffix)"
    }
}

actor CodexMonitor {
    typealias SnapshotHandler = @MainActor @Sendable (TokenBarSnapshot) -> Void

    private struct SessionFileState: Codable {
        var offset: UInt64 = 0
        var trailingData = Data()
        var allTokensByDay = [Date: Int64]()
        var dailyUsage = [Date: CodexDailyUsage]()
        var currentModelID: String?
        var activeTurns = Set<String>()
        var latestTerminalEvent: TerminalEvent?
        var latestRateLimits: RateLimitEvent?
        var latestPlanType: PlanTypeEvent?
        var modificationDate: Date?
        var fileIdentifier: UInt64?
    }

    private struct TerminalEvent: Codable {
        let date: Date
        let isError: Bool
    }

    private struct RateLimitEvent: Codable {
        let date: Date
        let snapshot: SessionRecord.RateLimits
    }

    private struct PlanTypeEvent: Codable {
        let date: Date
        let value: String
    }

    private struct UsageCache: Codable {
        let version: Int
        let codexHomePath: String
        let timeZoneIdentifier: String
        let files: [CachedSessionFile]
    }

    private struct CachedSessionFile: Codable {
        let path: String
        let state: SessionFileState
    }

    // Standard API prices per 1M tokens as of July 18, 2026.
    // https://platform.openai.com/docs/pricing
    private func rates(for model: CodexTrackedModel) -> APIRates {
        switch model {
        case .sol:
            APIRates(input: 5, cachedInput: 0.5, cacheWriteInput: 6.25, output: 30)
        case .terra:
            APIRates(input: 2.5, cachedInput: 0.25, cacheWriteInput: 3.125, output: 15)
        case .luna:
            APIRates(input: 1, cachedInput: 0.1, cacheWriteInput: 1.25, output: 6)
        }
    }

    private func cost(
        for usage: SessionRecord.TokenUsage,
        model: CodexTrackedModel
    ) -> Decimal {
        let regularInputTokens = usage.inputTokens
            - usage.cachedInputTokens
            - usage.cacheWriteInputTokens
        let rates = rates(for: model)
        let costPerMillion = Decimal(regularInputTokens) * rates.input
            + Decimal(usage.cachedInputTokens) * rates.cachedInput
            + Decimal(usage.cacheWriteInputTokens) * rates.cacheWriteInput
            + Decimal(usage.outputTokens) * rates.output
        return costPerMillion / 1_000_000
    }

    private struct APIRates {
        let input: Decimal
        let cachedInput: Decimal
        let cacheWriteInput: Decimal
        let output: Decimal
    }

    private struct TurnContextRecord: Decodable {
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let model: String
        }
    }

    private struct SessionRecord: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload

        struct Payload: Decodable {
            let type: String
            let turnID: String?
            let reason: String?
            let info: UsageInfo?
            let rateLimits: RateLimits?

            enum CodingKeys: String, CodingKey {
                case type
                case turnID = "turn_id"
                case reason
                case info
                case rateLimits = "rate_limits"
            }
        }

        struct RateLimits: Codable {
            let primary: Window?
            let secondary: Window?
            let planType: String?

            enum CodingKeys: String, CodingKey {
                case primary
                case secondary
                case planType = "plan_type"
            }

            struct Window: Codable {
                let usedPercent: Double
                let resetsAt: TimeInterval?
                let windowMinutes: Int64?

                enum CodingKeys: String, CodingKey {
                    case usedPercent = "used_percent"
                    case resetsAt = "resets_at"
                    case windowMinutes = "window_minutes"
                }
            }
        }

        struct UsageInfo: Decodable {
            let lastTokenUsage: TokenUsage?

            enum CodingKeys: String, CodingKey {
                case lastTokenUsage = "last_token_usage"
            }
        }

        struct TokenUsage: Decodable {
            let inputTokens: Int64
            let cachedInputTokens: Int64
            let cacheWriteInputTokens: Int64
            let outputTokens: Int64
            let totalTokens: Int64

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cachedInputTokens = "cached_input_tokens"
                case cacheWriteInputTokens = "cache_write_input_tokens"
                case outputTokens = "output_tokens"
                case totalTokens = "total_tokens"
            }
        }
    }

    private enum MonitorError: Error {
        case codexStorageUnavailable
        case sqliteOpenFailed
        case sqliteQueryFailed
    }

    private let fileManager: FileManager
    private let codexHome: URL
    private let databaseURL: URL
    private let sessionsURL: URL
    private let cacheURL: URL
    private let decoder = JSONDecoder()
    private let timestampFormatter: ISO8601DateFormatter
    private let pollInterval: Duration
    private var fileStates = [URL: SessionFileState]()
    private var monitoredDayStart: Date?
    private var monitoredTimeZoneIdentifier: String?

    init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        fileManager: FileManager = .default,
        pollInterval: Duration = .seconds(2),
        cacheURL: URL? = nil
    ) {
        self.codexHome = codexHome
        self.fileManager = fileManager
        self.pollInterval = pollInterval
        databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        sessionsURL = codexHome.appendingPathComponent("sessions", isDirectory: true)
        self.cacheURL = cacheURL ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenBar", isDirectory: true)
            .appendingPathComponent("usage-history.json")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter
    }

    func run(handler: @escaping SnapshotHandler) async {
        var needsFullRefresh = true
        var isColdLaunch = true

        while !Task.isCancelled {
            let now = Date()

            do {
                let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: now)
                let timeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
                if monitoredTimeZoneIdentifier != timeZoneIdentifier {
                    fileStates.removeAll(keepingCapacity: true)
                    needsFullRefresh = true
                } else if monitoredDayStart != dayStart {
                    needsFullRefresh = true
                }

                if needsFullRefresh {
                    try rebuild(now: now, isColdLaunch: isColdLaunch)
                    needsFullRefresh = false
                    isColdLaunch = false
                } else {
                    try refresh(now: now)
                }

                await handler(makeSnapshot(now: now))
            } catch {
                await handler(
                    TokenBarSnapshot(status: .unavailable, todayTokens: 0, lastUpdated: now)
                )
                needsFullRefresh = true
            }

            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return
            }
        }
    }

    private func rebuild(now: Date, isColdLaunch: Bool) throws {
        try validateCodexStorage()

        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: now)
        let historyStart = calendar.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let historyInterval = DateInterval(start: historyStart, end: dayEnd)
        let activeLookback = now.addingTimeInterval(-30 * 60)
        let urls = try rolloutURLs(updatedSince: historyStart)

        if fileStates.isEmpty {
            fileStates = loadCache()
        }
        let cachedFileCount = fileStates.count
        fileStates = fileStates.filter { urls.contains($0.key) }
        monitoredDayStart = dayStart
        monitoredTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier

        var cacheChanged = fileStates.count != cachedFileCount
        for url in urls {
            if try refreshFile(at: url, historyInterval: historyInterval) {
                cacheChanged = true
            }
        }

        if isColdLaunch {
            for url in Array(fileStates.keys) {
                guard let modificationDate = fileStates[url]?.modificationDate,
                      modificationDate < activeLookback,
                      fileStates[url]?.activeTurns.isEmpty == false else {
                      continue
                }
                fileStates[url]?.activeTurns.removeAll()
                cacheChanged = true
            }
        }

        if pruneHistory(before: historyStart) {
            cacheChanged = true
        }
        if cacheChanged || !fileManager.fileExists(atPath: cacheURL.path) {
            saveCache()
        }
    }

    private func refresh(now: Date) throws {
        try validateCodexStorage()

        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: now)
        let historyStart = calendar.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let historyInterval = DateInterval(start: historyStart, end: dayEnd)
        let indexedURLs = try rolloutURLs(updatedSince: dayStart)

        var cacheChanged = false
        for url in indexedURLs {
            if try refreshFile(at: url, historyInterval: historyInterval) {
                cacheChanged = true
            }
        }
        if cacheChanged {
            saveCache()
        }
    }

    private func makeSnapshot(now: Date) -> TokenBarSnapshot {
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = monitoredDayStart ?? calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let days = (0..<30).compactMap { offset in
            calendar.date(byAdding: .day, value: offset - 29, to: dayStart)
        }
        var usageByDay = Dictionary(
            uniqueKeysWithValues: days.map { ($0, CodexDailyUsage(day: $0)) }
        )

        var totalTokens = Int64.zero
        for state in fileStates.values {
            totalTokens += state.allTokensByDay[dayStart, default: 0]
            for (day, usage) in state.dailyUsage where usageByDay[day] != nil {
                usageByDay[day]?.add(usage)
            }
        }

        let dailyUsage = days.compactMap { usageByDay[$0] }
        let todayUsage = dailyUsage.last ?? CodexDailyUsage(day: dayStart)
        let last30DaysTokens = dailyUsage.reduce(Int64.zero) { total, usage in
            total + usage.totalTokens
        }
        let last30DaysAPICostUSD = dailyUsage.reduce(Decimal.zero) { total, usage in
            total + usage.estimatedAPICostUSD
        }
        let hasActiveTurn = fileStates.values.contains { !$0.activeTurns.isEmpty }
        let latestTerminalEvent = fileStates.values
            .compactMap(\.latestTerminalEvent)
            .filter { $0.date >= dayStart && $0.date < dayEnd }
            .max { $0.date < $1.date }
        let latestRateLimits = fileStates.values
            .compactMap(\.latestRateLimits)
            .max { $0.date < $1.date }?
            .snapshot
        let subscriptionPlan = fileStates.values
            .compactMap(\.latestPlanType)
            .max { $0.date < $1.date }
            .flatMap { CodexSubscriptionPlan(planType: $0.value) }

        let status: CodexStatus
        if hasActiveTurn {
            status = .working
        } else if latestTerminalEvent?.isError == true {
            status = .error
        } else {
            status = .idle
        }

        return TokenBarSnapshot(
            status: status,
            todayTokens: totalTokens,
            lastUpdated: now,
            fiveHourLimit: rateLimitWindow(durationMinutes: 300, in: latestRateLimits),
            weeklyLimit: rateLimitWindow(durationMinutes: 10_080, in: latestRateLimits),
            estimatedAPICostUSD: todayUsage.estimatedAPICostUSD,
            trackedTodayTokens: todayUsage.totalTokens,
            last30DaysTokens: last30DaysTokens,
            last30DaysAPICostUSD: last30DaysAPICostUSD,
            dailyUsage: dailyUsage,
            subscriptionPlan: subscriptionPlan
        )
    }

    private func rateLimitWindow(
        durationMinutes: Int64,
        in snapshot: SessionRecord.RateLimits?
    ) -> CodexRateLimitWindow? {
        let windows = [snapshot?.primary, snapshot?.secondary].compactMap { $0 }
        guard let window = windows.first(where: { $0.windowMinutes == durationMinutes }) else {
            return nil
        }

        return CodexRateLimitWindow(
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func loadCache() -> [URL: SessionFileState] {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(UsageCache.self, from: data),
              cache.version == 2,
              cache.codexHomePath == codexHome.path,
              cache.timeZoneIdentifier == TimeZone.autoupdatingCurrent.identifier else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: cache.files.map { file in
            (URL(fileURLWithPath: file.path), file.state)
        })
    }

    private func saveCache() {
        let cache = UsageCache(
            version: 2,
            codexHomePath: codexHome.path,
            timeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
            files: fileStates.map { url, state in
                CachedSessionFile(path: url.path, state: state)
            }
        )

        guard let data = try? JSONEncoder().encode(cache) else { return }
        let directoryURL = cacheURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func pruneHistory(before historyStart: Date) -> Bool {
        var changed = false

        for url in Array(fileStates.keys) {
            guard var state = fileStates[url] else { continue }
            let tokenCount = state.allTokensByDay.count
            let usageCount = state.dailyUsage.count
            state.allTokensByDay = state.allTokensByDay.filter { $0.key >= historyStart }
            state.dailyUsage = state.dailyUsage.filter { $0.key >= historyStart }

            if state.allTokensByDay.count != tokenCount || state.dailyUsage.count != usageCount {
                fileStates[url] = state
                changed = true
            }
        }

        return changed
    }

    private func validateCodexStorage() throws {
        guard fileManager.isReadableFile(atPath: databaseURL.path),
              fileManager.isReadableFile(atPath: sessionsURL.path) else {
            throw MonitorError.codexStorageUnavailable
        }
    }

    private func rolloutURLs(updatedSince date: Date) throws -> Set<URL> {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX

        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database {
                sqlite3_close(database)
            }
            throw MonitorError.sqliteOpenFailed
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 500)

        let sql = "SELECT rollout_path FROM threads WHERE updated_at_ms >= ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MonitorError.sqliteQueryFailed
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(date.timeIntervalSince1970 * 1_000))

        var urls = Set<URL>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let path = sqlite3_column_text(statement, 0) else { continue }
                urls.insert(URL(fileURLWithPath: String(cString: path)))
            case SQLITE_DONE:
                return urls
            default:
                throw MonitorError.sqliteQueryFailed
            }
        }
    }

    @discardableResult
    private func refreshFile(at url: URL, historyInterval: DateInterval) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return fileStates.removeValue(forKey: url) != nil
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value

        var state = fileStates[url, default: SessionFileState()]
        let wasReplaced = state.fileIdentifier != nil && state.fileIdentifier != fileIdentifier
        let wasRewrittenAtSameSize = fileSize == state.offset
            && state.modificationDate != nil
            && state.modificationDate != modificationDate
        var changed = false
        if fileSize < state.offset || wasReplaced || wasRewrittenAtSameSize {
            state = SessionFileState()
            changed = true
        }
        state.modificationDate = modificationDate
        state.fileIdentifier = fileIdentifier

        guard fileSize > state.offset else {
            fileStates[url] = state
            return changed
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)

        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            state.offset += UInt64(data.count)
            process(data: data, historyInterval: historyInterval, state: &state)
        }

        fileStates[url] = state
        return true
    }

    private func process(
        data: Data,
        historyInterval: DateInterval,
        state: inout SessionFileState
    ) {
        var buffer = state.trailingData
        buffer.append(data)

        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            process(
                line: Data(buffer[lineStart..<newline]),
                historyInterval: historyInterval,
                state: &state
            )
            lineStart = buffer.index(after: newline)
        }

        state.trailingData = Data(buffer[lineStart...])
    }

    private func process(
        line: Data,
        historyInterval: DateInterval,
        state: inout SessionFileState
    ) {
        if line.range(of: Data(#""type":"turn_context""#.utf8)) != nil,
           let record = try? decoder.decode(TurnContextRecord.self, from: line),
           record.type == "turn_context" {
            state.currentModelID = record.payload.model
            return
        }

        guard containsRelevantEvent(in: line),
              let record = try? decoder.decode(SessionRecord.self, from: line),
              record.type == "event_msg",
              let date = timestampFormatter.date(from: record.timestamp) else {
            return
        }

        switch record.payload.type {
        case "token_count":
            if let rateLimits = record.payload.rateLimits {
                state.latestRateLimits = RateLimitEvent(date: date, snapshot: rateLimits)
                if let planType = rateLimits.planType {
                    state.latestPlanType = PlanTypeEvent(date: date, value: planType)
                }
            }

            guard date >= historyInterval.start,
                  date < historyInterval.end,
                  let usage = record.payload.info?.lastTokenUsage else {
                return
            }
            let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
            state.allTokensByDay[day, default: 0] += usage.totalTokens

            guard let currentModelID = state.currentModelID,
                  let model = CodexTrackedModel(rawValue: currentModelID) else {
                return
            }

            var dailyUsage = state.dailyUsage[day] ?? CodexDailyUsage(day: day)
            dailyUsage.add(
                tokens: usage.totalTokens,
                cost: cost(for: usage, model: model),
                for: model
            )
            state.dailyUsage[day] = dailyUsage

        case "task_started":
            guard let turnID = record.payload.turnID else { return }
            state.activeTurns.insert(turnID)

        case "task_complete":
            guard let turnID = record.payload.turnID else { return }
            state.activeTurns.remove(turnID)
            state.latestTerminalEvent = TerminalEvent(date: date, isError: false)

        case "turn_aborted":
            guard let turnID = record.payload.turnID else { return }
            state.activeTurns.remove(turnID)
            state.latestTerminalEvent = TerminalEvent(
                date: date,
                isError: record.payload.reason != "interrupted"
            )

        default:
            return
        }
    }

    private func containsRelevantEvent(in line: Data) -> Bool {
        let markers = [
            #""type":"token_count""#,
            #""type":"task_started""#,
            #""type":"task_complete""#,
            #""type":"turn_aborted""#,
        ]
        return markers.contains { marker in
            line.range(of: Data(marker.utf8)) != nil
        }
    }
}
