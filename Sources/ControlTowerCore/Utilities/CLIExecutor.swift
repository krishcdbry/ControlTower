import Foundation

/// Executes CLI commands and parses output.
public enum CLIExecutor {
    /// Result of a CLI execution.
    public struct Result: Sendable {
        public let output: String
        public let errorOutput: String
        public let exitCode: Int32

        public var isSuccess: Bool { exitCode == 0 }
    }

    /// Find the path to an executable.
    public static func findExecutable(_ name: String) -> URL? {
        // Check common paths
        let paths = [
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/bin/\(name)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin/\(name)",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/bin/\(name)",
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // Try `which` command
        let whichResult = try? runSync(executable: "/usr/bin/which", arguments: [name])
        if let output = whichResult?.output.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty,
           FileManager.default.isExecutableFile(atPath: output) {
            return URL(fileURLWithPath: output)
        }

        return nil
    }

    /// Run a command synchronously.
    public static func runSync(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let env = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in env {
                processEnv[key] = value
            }
            process.environment = processEnv
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = nil

        // Use sendable boxes for thread-safe data collection
        let outputBox = SendableBox<Data>()
        let errorBox = SendableBox<Data>()
        let outputGroup = DispatchGroup()

        outputGroup.enter()
        DispatchQueue.global().async {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            outputBox.value = data
            outputGroup.leave()
        }

        outputGroup.enter()
        DispatchQueue.global().async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errorBox.value = data
            outputGroup.leave()
        }

        try process.run()
        process.waitUntilExit()

        // Wait for output with timeout
        let waitResult = outputGroup.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            throw CLIError.timeout
        }

        return Result(
            output: String(data: outputBox.value ?? Data(), encoding: .utf8) ?? "",
            errorOutput: String(data: errorBox.value ?? Data(), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Thread-safe box for collecting data from async operations.
    private final class SendableBox<T>: @unchecked Sendable {
        var value: T?
    }

    /// Run a command asynchronously.
    public static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let result = try runSync(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        timeout: timeout
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Run a CLI tool by name (finds it automatically).
    public static func runTool(
        _ name: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Result {
        guard let executable = findExecutable(name) else {
            throw CLIError.executableNotFound(name)
        }
        return try await run(
            executable: executable.path,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        )
    }
}

/// CLI execution errors.
public enum CLIError: LocalizedError, Sendable {
    case executableNotFound(String)
    case timeout
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "Executable not found: \(name)"
        case .timeout:
            return "Command timed out"
        case .executionFailed(let message):
            return "Execution failed: \(message)"
        }
    }
}
