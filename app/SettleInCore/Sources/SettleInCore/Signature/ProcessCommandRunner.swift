import Foundation

/// Runs a program with `Process`. It passes the argument array to the program directly.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        guard executable.isFileURL, executable.path.hasPrefix("/") else {
            throw CommandRunnerError.executableNotAbsolute(executable.absoluteString)
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try Self.runBlocking(executable: executable, arguments: arguments) })
            }
        }
    }

    /// Runs on a background queue, because it waits for the program to exit. Two readers drain stdout
    /// and stderr at the same time, so a program that fills one pipe cannot block.
    private static func runBlocking(executable: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // A fixed environment keeps the tool output in English and drops inherited variables such as DYLD_*.
        process.environment = ["LC_ALL": "C"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

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
        group.wait()
        process.waitUntilExit()

        // A program that a signal ended reports 128 plus the signal number, as a shell does.
        let exitCode = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus
            : process.terminationStatus
        return CommandResult(
            exitCode: exitCode,
            stdout: text(stdoutBox.data),
            stderr: text(stderrBox.data)
        )
    }

    /// Latin-1 accepts every byte sequence, so odd output from a tool still reaches the parsers.
    private static func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }
}

/// Holds the bytes one reader collected. `group.wait()` orders the write before the read.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
