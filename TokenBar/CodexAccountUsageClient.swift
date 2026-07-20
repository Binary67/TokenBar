//
//  CodexAccountUsageClient.swift
//  TokenBar
//

import Foundation

nonisolated struct CodexAccountUsage: Codable, Equatable, Sendable {
    struct DailyBucket: Codable, Equatable, Sendable {
        let startDate: String
        let tokens: Int64
    }

    let dailyUsageBuckets: [DailyBucket]?
}

struct CodexAccountUsageClient: Sendable {
    let fetch: @Sendable () async throws -> CodexAccountUsage

    nonisolated static func live(
        executableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    ) -> CodexAccountUsageClient {
        CodexAccountUsageClient {
            try await Task.detached(priority: .utility) {
                try fetchUsage(executableURL: executableURL)
            }.value
        }
    }

    nonisolated private static func fetchUsage(executableURL: URL) throws -> CodexAccountUsage {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executableURL.deletingLastPathComponent().path
        environment["PATH"] = [executableDirectory, environment["PATH"]]
            .compactMap { $0 }
            .joined(separator: ":")
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        var reader = JSONLineReader(handle: outputPipe.fileHandleForReading)
        try write(
            """
            {"method":"initialize","id":0,"params":{"clientInfo":{"name":"tokenbar","title":"TokenBar","version":"1.0"}}}
            """,
            to: inputPipe.fileHandleForWriting
        )
        _ = try reader.response(id: 0)

        try write(
            """
            {"method":"initialized","params":{}}
            {"method":"account/usage/read","id":1}
            """,
            to: inputPipe.fileHandleForWriting
        )
        let response = try reader.response(id: 1)
        try inputPipe.fileHandleForWriting.close()

        guard let usage = response.result else {
            throw CodexAccountUsageError.missingResult
        }
        return usage
    }

    nonisolated private static func write(_ message: String, to handle: FileHandle) throws {
        guard let data = "\(message)\n".data(using: .utf8) else {
            throw CodexAccountUsageError.invalidRequest
        }
        try handle.write(contentsOf: data)
    }
}

nonisolated private struct CodexAccountUsageResponse: Decodable {
    struct ResponseError: Decodable {
        let message: String
    }

    let id: Int?
    let result: CodexAccountUsage?
    let error: ResponseError?
}

private struct JSONLineReader {
    let handle: FileHandle
    private var buffer = Data()

    nonisolated init(handle: FileHandle) {
        self.handle = handle
    }

    nonisolated mutating func response(id: Int) throws -> CodexAccountUsageResponse {
        let decoder = JSONDecoder()
        while true {
            let line = try nextLine()
            guard let response = try? decoder.decode(CodexAccountUsageResponse.self, from: line),
                  response.id == id else {
                continue
            }
            if let error = response.error {
                throw CodexAccountUsageError.server(error.message)
            }
            return response
        }
    }

    nonisolated private mutating func nextLine() throws -> Data {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                if !line.isEmpty {
                    return Data(line)
                }
            }

            let data = handle.availableData
            guard !data.isEmpty else {
                throw CodexAccountUsageError.disconnected
            }
            buffer.append(data)
        }
    }
}

private enum CodexAccountUsageError: Error {
    case disconnected
    case invalidRequest
    case missingResult
    case server(String)
}
