import Foundation

/// What a finished command printed and how it exited.
public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Both streams as one text. The signing tools print some results to stdout and others to stderr.
    var combinedOutput: String { stdout + "\n" + stderr }
}

public enum CommandRunnerError: Error, Equatable {
    case executableNotAbsolute(String)
}

/// Runs one program with an argument list. An implementation never builds a command from a string
/// and never starts a shell.
public protocol CommandRunner: Sendable {
    /// `executable` is the absolute file URL of the program. Each element of `arguments` reaches the
    /// program as one argument, with no further parsing.
    func run(executable: URL, arguments: [String]) async throws -> CommandResult
}
