import Foundation

/// Why an operation ended in `failed`. Each case wraps the typed error of one engine part.
public enum InstallFailure: Error, Equatable, Sendable {
    case download(DownloadError)
    /// A dmg or zip install failed. A signature failure of the staged copy arrives as
    /// `InstallError.signatureInvalid`.
    case install(InstallError)
    /// A pkg install failed. A signature failure arrives as `PackageInstallFailure.signature`.
    case package(PackageInstallFailure)
    case uninstall(UninstallError)
    /// The uninstaller left some paths alone. The log lists them.
    case uninstallIncomplete(leftAlone: Int)
    /// The engine stopped without a final result.
    case interrupted
    /// An error the engine does not declare. The message never repeats the error's text.
    case unexpected

    /// Maps an error thrown by an engine part to a failure. `CancellationError` is not a failure, so
    /// callers handle it first.
    static func from(_ error: any Error) -> InstallFailure {
        switch error {
        case let failure as InstallFailure: failure
        case let error as DownloadError: .download(error)
        case let error as InstallError: .install(error)
        case let error as UninstallError: .uninstall(error)
        default: .unexpected
        }
    }

    /// One plain sentence for the user. It names tools and exit codes and never repeats tool output.
    /// The switch is exhaustive, so a new case does not compile until it has a message.
    public var userMessage: String {
        switch self {
        case .download(let error): error.message
        case .install(let error): error.message
        case .package(let failure): failure.message
        case .uninstall(let error): error.message
        case .uninstallIncomplete(let count):
            "SettleIn left \(count) \(count == 1 ? "item" : "items") alone because the path checks refused it. "
                + "The log lists them."
        case .interrupted: "The operation stopped before it finished. Try again."
        case .unexpected: "Something unexpected stopped the operation. Copy the log if you report it."
        }
    }

    /// The tool that failed and its exit code, when the failure came from a tool.
    var toolExit: (tool: String, exitCode: Int32)? {
        switch self {
        case .install(.signatureInvalid(let failure)), .package(.signature(let failure)):
            failure.toolExit
        case .download, .install, .package, .uninstall, .uninstallIncomplete, .interrupted, .unexpected:
            nil
        }
    }
}

extension SignatureFailure {
    var toolExit: (tool: String, exitCode: Int32)? {
        guard case .toolFailed(let tool, let exitCode) = self else { return nil }
        return (tool, exitCode)
    }
}
