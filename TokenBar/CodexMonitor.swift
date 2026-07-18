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

    var label: String {
        rawValue.capitalized
    }

    var symbolName: String {
        switch self {
        case .working:
            "circle.fill"
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

    private struct SessionFileState {
        var offset: UInt64 = 0
        var trailingData = Data()
        var todayTokens: Int64 = 0
        var activeTurns = Set<String>()
        var latestTerminalEvent: TerminalEvent?
        var latestRateLimits: RateLimitEvent?
        var modificationDate: Date?
        var fileIdentifier: UInt64?
    }

    private struct TerminalEvent {
        let date: Date
        let isError: Bool
    }

    private struct RateLimitEvent {
        let date: Date
        let snapshot: SessionRecord.RateLimits
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

        struct RateLimits: Decodable {
            let primary: Window?
            let secondary: Window?

            struct Window: Decodable {
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
            let totalTokens: Int64

            enum CodingKeys: String, CodingKey {
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
    private let decoder = JSONDecoder()
    private let timestampFormatter: ISO8601DateFormatter
    private let pollInterval: Duration
    private var fileStates = [URL: SessionFileState]()
    private var monitoredDayStart: Date?

    init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        fileManager: FileManager = .default,
        pollInterval: Duration = .seconds(2)
    ) {
        self.codexHome = codexHome
        self.fileManager = fileManager
        self.pollInterval = pollInterval
        databaseURL = codexHome.appendingPathComponent("state_5.sqlite")
        sessionsURL = codexHome.appendingPathComponent("sessions", isDirectory: true)

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
                if monitoredDayStart != dayStart {
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
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let dayInterval = DateInterval(start: dayStart, end: dayEnd)
        let activeLookback = now.addingTimeInterval(-30 * 60)
        let queryStart = min(dayStart, activeLookback)

        fileStates.removeAll(keepingCapacity: true)
        monitoredDayStart = dayStart

        for url in try rolloutURLs(updatedSince: queryStart) {
            try refreshFile(at: url, dayInterval: dayInterval, reset: true)
        }

        if isColdLaunch {
            for url in fileStates.keys {
                guard let modificationDate = fileStates[url]?.modificationDate,
                      modificationDate < activeLookback else {
                    continue
                }
                fileStates[url]?.activeTurns.removeAll()
            }
        }
    }

    private func refresh(now: Date) throws {
        try validateCodexStorage()

        let calendar = Calendar.autoupdatingCurrent
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let dayInterval = DateInterval(start: dayStart, end: dayEnd)
        let indexedURLs = try rolloutURLs(updatedSince: dayStart)
        let urls = Set(fileStates.keys).union(indexedURLs)

        for url in urls {
            try refreshFile(at: url, dayInterval: dayInterval, reset: false)
        }
    }

    private func makeSnapshot(now: Date) -> TokenBarSnapshot {
        let totalTokens = fileStates.values.reduce(Int64(0)) { total, state in
            total + state.todayTokens
        }
        let hasActiveTurn = fileStates.values.contains { !$0.activeTurns.isEmpty }
        let calendar = Calendar.autoupdatingCurrent
        let dayStart = monitoredDayStart ?? calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now
        let latestTerminalEvent = fileStates.values
            .compactMap(\.latestTerminalEvent)
            .filter { $0.date >= dayStart && $0.date < dayEnd }
            .max { $0.date < $1.date }
        let latestRateLimits = fileStates.values
            .compactMap(\.latestRateLimits)
            .max { $0.date < $1.date }?
            .snapshot

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
            weeklyLimit: rateLimitWindow(durationMinutes: 10_080, in: latestRateLimits)
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

    private func refreshFile(at url: URL, dayInterval: DateInterval, reset: Bool) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            fileStates.removeValue(forKey: url)
            return
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value

        var state = reset ? SessionFileState() : fileStates[url, default: SessionFileState()]
        let wasReplaced = state.fileIdentifier != nil && state.fileIdentifier != fileIdentifier
        let wasRewrittenAtSameSize = fileSize == state.offset
            && state.modificationDate != nil
            && state.modificationDate != modificationDate
        if fileSize < state.offset || wasReplaced || wasRewrittenAtSameSize {
            state = SessionFileState()
        }
        state.modificationDate = modificationDate
        state.fileIdentifier = fileIdentifier

        guard fileSize > state.offset else {
            fileStates[url] = state
            return
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: state.offset)

        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            state.offset += UInt64(data.count)
            process(data: data, dayInterval: dayInterval, state: &state)
        }

        fileStates[url] = state
    }

    private func process(data: Data, dayInterval: DateInterval, state: inout SessionFileState) {
        var buffer = state.trailingData
        buffer.append(data)

        var lineStart = buffer.startIndex
        while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            process(
                line: Data(buffer[lineStart..<newline]),
                dayInterval: dayInterval,
                state: &state
            )
            lineStart = buffer.index(after: newline)
        }

        state.trailingData = Data(buffer[lineStart...])
    }

    private func process(line: Data, dayInterval: DateInterval, state: inout SessionFileState) {
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
            }

            guard date >= dayInterval.start,
                  date < dayInterval.end,
                  let tokens = record.payload.info?.lastTokenUsage?.totalTokens else {
                return
            }
            state.todayTokens += tokens

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
