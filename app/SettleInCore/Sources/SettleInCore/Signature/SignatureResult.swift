import Foundation

/// The outcome of a signature check.
public enum SignatureResult: Equatable, Sendable {
    /// The signature is valid and carries the Team ID that the catalog names.
    case valid(TeamID)
    case invalid(SignatureFailure)
}

/// Why a signature check failed. Each case has a `reason` the UI can show.
public enum SignatureFailure: Error, Equatable, Sendable {
    case unsigned
    case brokenSignature(detail: String)
    case gatekeeperRejected(detail: String)
    case teamIDMissing
    case teamIDMismatch(expected: String, actual: String)
    case toolFailed(tool: String, exitCode: Int32)

    /// The `toolFailed` exit code for a tool that never started.
    public static let toolDidNotStart: Int32 = -1

    public var reason: String {
        switch self {
        case .unsigned:
            return "The file is not signed, so SettleIn cannot tell who made it."
        case .brokenSignature(let detail):
            return "The signature is not valid. The check tool reported: \(detail)"
        case .gatekeeperRejected(let detail):
            return "macOS Gatekeeper rejected the app. spctl reported: \(detail)"
        case .teamIDMissing:
            return "The signature has no Team ID. Ad hoc signed apps and Apple's own apps have none, "
                + "and SettleIn does not accept them."
        case .teamIDMismatch(let expected, let actual):
            return "The signature belongs to Team ID \(actual), but the catalog expects Team ID \(expected)."
        case .toolFailed(let tool, let exitCode):
            if exitCode == Self.toolDidNotStart {
                return "SettleIn could not start the \(tool) tool, so it could not check the signature."
            }
            return "The \(tool) tool failed with exit code \(exitCode), so SettleIn could not check the signature."
        }
    }
}
