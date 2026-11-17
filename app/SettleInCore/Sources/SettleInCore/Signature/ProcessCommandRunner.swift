import Foundation

/// Runs a program with `Process`. It passes the argument array to the program directly.
///
/// Cancelling the task that calls `run` ends the program. The runner sends SIGTERM, and sends SIGKILL when the
/// program is still alive after `terminationGrace`. `run` then throws `CancellationError`. It throws after the
/// program has ended. A grandchild can keep the output pipes open after SIGKILL, so `run` waits at most 2 more
/// seconds for the pipes, then closes them and throws anyway.
public struct ProcessCommandRunner: CommandRunner {
    private let terminationGrace: Duration

    public init(terminationGrace: Duration = .seconds(2)) {
        self.terminationGrace = terminationGrace
    }

    public func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        guard executable.isFileURL, executable.path.hasPrefix("/") else {
            throw CommandRunnerError.executableNotAbsolute(executable.absoluteString)
        }
        let child = ChildProcess(executable: executable, arguments: arguments, terminationGrace: terminationGrace)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result { try child.runToCompletion() })
                }
            }
        } onCancel: {
            child.cancel()
        }
    }
}

/// One program run. A lock guards the cancel flag and the launch, so a cancel that arrives before the launch
/// stops the program from starting, and a cancel that arrives after it signals the running program.
private final class ChildProcess: @unchecked Sendable {
    private let process = Process()
    private let terminationGrace: Duration
    private let lock = NSLock()
    private var cancelled = false
    private var hardDeadline: ContinuousClock.Instant?
    private static let pipeWait: Duration = .seconds(2)

    init(executable: URL, arguments: [String], terminationGrace: Duration) {
        process.executableURL = executable
        process.arguments = arguments
        // A fixed environment keeps the tool output in English and drops inherited variables such as DYLD_*.
        process.environment = ["LC_ALL": "C"]
        self.terminationGrace = terminationGrace
    }

    func cancel() {
        let isRunning = lock.withLock {
            cancelled = true
            hardDeadline = ContinuousClock.now + terminationGrace + Self.pipeWait
            return process.isRunning
        }
        guard isRunning else { return }
        process.terminate()
        let seconds = Double(terminationGrace.components.seconds)
            + Double(terminationGrace.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            let stillRunning = lock.withLock { process.isRunning }
            if stillRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Runs on a background queue, because it waits for the program to exit. Two readers drain stdout
    /// and stderr at the same time, so a program that fills one pipe cannot block.
    func runToCompletion() throws -> CommandResult {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
        }

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let group = DispatchGroup()
        for (pipe, box) in [(stdoutPipe, stdoutBox), (stderrPipe, stderrBox)] {
            group.enter()
            DispatchQueue.global().async {
                box.data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                group.leave()
            }
        }
        while group.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            guard let deadline = lock.withLock({ hardDeadline }), ContinuousClock.now >= deadline else { continue }
            // A grandchild still holds the pipes. The readers stay blocked until it ends, and the caller moves on.
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw CancellationError()
        }
        process.waitUntilExit()
        if lock.withLock({ cancelled }) { throw CancellationError() }

        // A program that a signal ended reports 128 plus the signal number, as a shell does.
        let exitCode = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus
            : process.terminationStatus
        return CommandResult(
            exitCode: exitCode,
            stdout: Self.text(stdoutBox.data),
            stderr: Self.text(stderrBox.data)
        )
    }

    /// Latin-1 accepts every byte sequence, so odd output from a tool still reaches the parsers.
    private static func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }
}

/// Holds the bytes one reader collected. The group wait orders the write before the read.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
