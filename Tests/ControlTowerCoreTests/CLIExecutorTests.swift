import Foundation
import Testing
@testable import ControlTowerCore

@Suite("CLIExecutor Tests")
struct CLIExecutorTests {
    @Test("Run echo command")
    func runEchoCommand() async throws {
        let result = try await CLIExecutor.run(
            executable: "/bin/echo",
            arguments: ["hello", "world"],
            timeout: 5
        )

        #expect(result.isSuccess)
        #expect(result.exitCode == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
    }

    @Test("Run pwd command")
    func runPwdCommand() async throws {
        let result = try await CLIExecutor.run(
            executable: "/bin/pwd",
            timeout: 5
        )

        #expect(result.isSuccess)
        #expect(!result.output.isEmpty)
    }

    @Test("Run command with large output (ps)")
    func runLargeOutputCommand() async throws {
        let result = try await CLIExecutor.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="],
            timeout: 10
        )

        #expect(result.isSuccess)
        #expect(result.output.count > 1000) // ps output should be substantial
    }

    @Test("Command not found throws error")
    func commandNotFoundThrows() async {
        do {
            _ = try await CLIExecutor.run(
                executable: "/nonexistent/command",
                timeout: 5
            )
            Issue.record("Expected error to be thrown")
        } catch {
            // Expected
            #expect(true)
        }
    }

    @Test("Find executable works for common tools")
    func findExecutableWorks() {
        // These should exist on any macOS system
        #expect(CLIExecutor.findExecutable("ls") != nil)
        #expect(CLIExecutor.findExecutable("cat") != nil)

        // This should not exist
        #expect(CLIExecutor.findExecutable("nonexistent-tool-12345") == nil)
    }

    @Test("Run with environment variables")
    func runWithEnvironment() async throws {
        let result = try await CLIExecutor.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo $TEST_VAR"],
            environment: ["TEST_VAR": "hello_test"],
            timeout: 5
        )

        #expect(result.isSuccess)
        #expect(result.output.contains("hello_test"))
    }

    @Test("Sync run works")
    func syncRunWorks() throws {
        let result = try CLIExecutor.runSync(
            executable: "/bin/echo",
            arguments: ["sync", "test"],
            timeout: 5
        )

        #expect(result.isSuccess)
        #expect(result.output.contains("sync test"))
    }
}
