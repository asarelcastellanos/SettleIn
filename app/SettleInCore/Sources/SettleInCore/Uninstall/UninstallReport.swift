import Foundation

/// What happened to one path.
public enum UninstallOutcome: Equatable, Sendable {
    /// The item went to the Trash.
    case trashed
    /// The Trash failed, so the item was deleted for good.
    case deleted
    /// Nothing is at the path.
    case skipped
    /// The path was left alone, for the stated reason.
    case refused(reason: String)
}

public struct UninstallItem: Equatable, Sendable {
    public let path: String
    public let outcome: UninstallOutcome
}

/// One item per path, in the order the uninstaller processed them. The app comes first.
public struct UninstallReport: Equatable, Sendable {
    public let items: [UninstallItem]
}

/// Why an uninstall stopped before it removed anything.
public enum UninstallError: Error, Equatable, Sendable, LocalizedError {
    /// The user answered no when asked to quit the running app.
    case quitDeclined
    /// The app did not quit, or it was still running after the wait.
    case appStillRunning

    public var errorDescription: String? {
        switch self {
        case .quitDeclined:
            return "The app is running and was not asked to quit, so SettleIn removed nothing."
        case .appStillRunning:
            return "The app is still running, so SettleIn removed nothing. Quit the app and try again."
        }
    }
}
