import Foundation

enum CommandRunner {
    struct Failure: Error, CustomStringConvertible {
        let command: String
        let status: Int32
        let stderr: String
        var description: String { "\(command) failed (\(status)): \(stderr)" }
    }

    /// Runs a command off the main thread and returns its standard output.
    /// Output is read while the process runs, so large outputs can't deadlock the pipe.
    static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()

            // Drain stderr concurrently so a chatty tool can't fill its pipe and block.
            let errorTask = Task.detached { (try? stderr.fileHandleForReading.readToEnd()) ?? Data() }
            let output = (try stdout.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let errorOutput = await errorTask.value

            guard process.terminationStatus == 0 else {
                throw Failure(
                    command: ([executable] + arguments.prefix(3)).joined(separator: " "),
                    status: process.terminationStatus,
                    stderr: String(decoding: errorOutput, as: UTF8.self)
                )
            }
            return String(decoding: output, as: UTF8.self)
        }.value
    }

    static func xcrun(_ arguments: [String]) async throws -> String {
        try await run("/usr/bin/xcrun", arguments)
    }
}
