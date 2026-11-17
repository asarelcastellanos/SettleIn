import Foundation
import Testing
@testable import SettleInCore

/// Every helper child carries a marker with a UUID in its arguments, so `pkill -f` finds that child and no
/// other. A SIGTERM-proof child needs SIGKILL, so the cleanup uses `pkill -9`. Each test ends its own children
/// in a `defer`, and an exit handler ends every child of this test run, so a failing run leaves none behind.
private let runMarker = "SettleInCancelTest-\(UUID().uuidString)"

private func killChildren(matching text: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-9", "-f", text]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

private let exitCleanup: Void = {
    atexit { killChildren(matching: runMarker) }
}()

private func isRunning(matching text: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", text]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Marks that the task is over, so a test can wait for it with a time limit and not hang on a failure.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

struct ProcessCommandRunnerCancelTests {
    private static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    /// A marker that is unique to one test, and that starts with the marker of the whole run.
    private static func marker() -> String {
        _ = exitCleanup
        return "\(runMarker)-\(UUID().uuidString)"
    }

    /// A child that sleeps for `seconds` and dies on SIGTERM, with the marker in its arguments.
    private static func sleeper(_ marker: String, seconds: Int = 600) -> [String] {
        ["-e", "sleep $ARGV[0];", String(seconds), marker]
    }

    @Test func cancellingTheTaskEndsTheChildAndThrowsCancellation() async throws {
        let marker = Self.marker()
        defer { killChildren(matching: marker) }
        let done = Flag()
        let task = Task { () -> CommandResult in
            defer { done.set() }
            return try await ProcessCommandRunner().run(executable: Self.perl, arguments: Self.sleeper(marker))
        }
        #expect(await eventually { isRunning(matching: marker) })

        task.cancel()

        #expect(await eventually { done.isSet }, "run did not return after the cancel")
        guard done.isSet else { return }
        guard case .failure(let error) = await task.result else {
            Issue.record("run returned a result after the cancel")
            return
        }
        #expect(error is CancellationError)
        #expect(!isRunning(matching: marker), "the child is still running after run returned")
    }

    @Test func aTerminateSignalAloneEndsAPlainChildLongBeforeTheGracePeriod() async throws {
        let marker = Self.marker()
        defer { killChildren(matching: marker) }
        let done = Flag()
        let runner = ProcessCommandRunner(terminationGrace: .seconds(30))
        let task = Task { () -> CommandResult in
            defer { done.set() }
            return try await runner.run(executable: Self.perl, arguments: Self.sleeper(marker))
        }
        #expect(await eventually { isRunning(matching: marker) })
        let start = ContinuousClock.now

        task.cancel()

        #expect(await eventually { done.isSet }, "the child outlived the terminate signal")
        #expect(ContinuousClock.now - start < .seconds(5), "the runner waited for the 30 second grace period")
        #expect(!isRunning(matching: marker))
    }

    @Test func aChildThatIgnoresTheTerminateSignalIsKilledAfterTheGracePeriod() async throws {
        let marker = Self.marker()
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("\(marker).ready")
        defer {
            killChildren(matching: marker)
            try? FileManager.default.removeItem(at: ready)
        }
        let script = #"$SIG{TERM} = "IGNORE"; open(F, ">", $ARGV[0]); close(F); sleep $ARGV[1];"#
        let done = Flag()
        let runner = ProcessCommandRunner(terminationGrace: .milliseconds(300))
        let task = Task { () -> CommandResult in
            defer { done.set() }
            return try await runner.run(executable: Self.perl, arguments: ["-e", script, ready.path, "600", marker])
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: ready.path) })
        let start = ContinuousClock.now

        task.cancel()

        #expect(await eventually { done.isSet }, "run did not return after the cancel")
        guard done.isSet else { return }
        #expect(ContinuousClock.now - start >= .milliseconds(250), "the child ended before the grace period")
        #expect(!isRunning(matching: marker))
        if case .failure(let error) = await task.result { #expect(error is CancellationError) }
    }

    @Test func aGrandchildThatKeepsThePipesOpenDoesNotHoldRunBeyondTwoMoreSeconds() async throws {
        let marker = Self.marker()
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("\(marker).ready")
        defer {
            killChildren(matching: marker)
            try? FileManager.default.removeItem(at: ready)
        }
        // The shell ignores TERM, then starts a background sleep that holds the pipes and outlives the shell.
        let script = #"trap "" TERM; : > "$1"; /usr/bin/perl -e 'sleep $ARGV[0];' 600 "$2" & wait"#
        let done = Flag()
        let runner = ProcessCommandRunner(terminationGrace: .milliseconds(300))
        let task = Task { () -> CommandResult in
            defer { done.set() }
            return try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "sh", ready.path, marker]
            )
        }
        #expect(await eventually { FileManager.default.fileExists(atPath: ready.path) })
        let start = ContinuousClock.now

        task.cancel()

        #expect(await eventually { done.isSet }, "run waited for the grandchild")
        guard done.isSet else { return }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(5))
        if case .failure(let error) = await task.result { #expect(error is CancellationError) }
        #expect(isRunning(matching: marker), "the test needs the grandchild to outlive run")
    }

    @Test func aTaskCancelledBeforeTheLaunchNeverStartsTheChild() async throws {
        let marker = Self.marker()
        defer { killChildren(matching: marker) }
        let done = Flag()
        let task = Task { () -> CommandResult in
            defer { done.set() }
            while !Task.isCancelled { await Task.yield() }
            return try await ProcessCommandRunner().run(executable: Self.perl, arguments: Self.sleeper(marker))
        }

        task.cancel()

        #expect(await eventually { done.isSet }, "run did not return after the cancel")
        guard done.isSet else { return }
        if case .failure(let error) = await task.result { #expect(error is CancellationError) }
        #expect(!isRunning(matching: marker))
    }

    @Test func aCommandThatFinishesBeforeAnyCancelReturnsItsResult() async throws {
        let result = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0"]
        )
        #expect(result.exitCode == 0)
    }
}
