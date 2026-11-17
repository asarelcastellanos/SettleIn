import Foundation
import Testing
@testable import SettleInCore

/// Cancelling the task that runs a command must end the child process. Each test starts a real child with a
/// unique argument, so `pgrep` finds that child and no other, and every test ends any child that is left.
struct ProcessCommandRunnerCancelTests {
    private static let sleep = URL(fileURLWithPath: "/bin/sleep")

    private static func uniqueSleepSeconds() -> String { "7\(Int.random(in: 100_000...999_999))" }

    private static func isRunning(matching text: String) -> Bool {
        pgrep(["-f", text]) == 0
    }

    private static func endProcesses(matching text: String) {
        _ = pgrep(["-f", text], tool: "/usr/bin/pkill")
    }

    private static func pgrep(_ arguments: [String], tool: String = "/usr/bin/pgrep") -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Marks that the task is over, so a test can wait for it with a time limit and not hang on a failure.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    @Test func cancellingTheTaskEndsTheChildAndThrowsCancellation() async throws {
        let seconds = Self.uniqueSleepSeconds()
        defer { Self.endProcesses(matching: seconds) }
        let done = Flag()
        let task = Task { () -> CommandResult in
            defer { done.set() }
            return try await ProcessCommandRunner().run(executable: Self.sleep, arguments: [seconds])
        }
        #expect(await eventually { Self.isRunning(matching: seconds) })

        task.cancel()

        #expect(await eventually { done.isSet }, "run did not return after the cancel")
        guard done.isSet else { return }
        let outcome = await task.result
        guard case .failure(let error) = outcome else {
            Issue.record("run returned a result after the cancel")
            return
        }
        #expect(error is CancellationError)
        #expect(!Self.isRunning(matching: seconds), "the child is still running after run returned")
    }

    @Test func aChildThatIgnoresTheTerminateSignalIsKilledAfterTheGracePeriod() async throws {
        let perl = "/usr/bin/perl"
        try #require(FileManager.default.isExecutableFile(atPath: perl))
        let seconds = Self.uniqueSleepSeconds()
        let ready = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettleIn-term-test-\(UUID().uuidString)")
        defer {
            Self.endProcesses(matching: seconds)
            try? FileManager.default.removeItem(at: ready)
        }
        let script = #"$SIG{TERM} = "IGNORE"; open(F, ">", $ARGV[0]); close(F); sleep $ARGV[1];"#
        let done = Flag()
        let runner = ProcessCommandRunner(terminationGrace: .milliseconds(300))
        let task = Task { () -> CommandResult in
            defer { done.set() }
            return try await runner.run(
                executable: URL(fileURLWithPath: perl), arguments: ["-e", script, ready.path, seconds]
            )
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: ready.path) })
        let start = ContinuousClock.now

        task.cancel()

        #expect(await eventually { done.isSet }, "run did not return after the cancel")
        guard done.isSet else { return }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(250), "the child ended before the grace period")
        #expect(!Self.isRunning(matching: seconds))
        if case .failure(let error) = await task.result { #expect(error is CancellationError) }
    }

    @Test func aTaskCancelledBeforeTheLaunchNeverStartsTheChild() async throws {
        let seconds = Self.uniqueSleepSeconds()
        defer { Self.endProcesses(matching: seconds) }
        let done = Flag()
        let task = Task { () -> CommandResult in
            defer { done.set() }
            while !Task.isCancelled { await Task.yield() }
            return try await ProcessCommandRunner().run(executable: Self.sleep, arguments: [seconds])
        }

        task.cancel()

        #expect(await eventually { done.isSet }, "run did not return after the cancel")
        guard done.isSet else { return }
        if case .failure(let error) = await task.result { #expect(error is CancellationError) }
        #expect(!Self.isRunning(matching: seconds))
    }

    @Test func aCommandThatFinishesBeforeAnyCancelReturnsItsResult() async throws {
        let result = try await ProcessCommandRunner().run(executable: Self.sleep, arguments: ["0"])
        #expect(result.exitCode == 0)
    }
}
