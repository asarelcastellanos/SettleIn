import Foundation

/// What `PackageInstaller` reports while one package installs. The stream ends after `installed`,
/// `cancelled`, or `failed`.
public enum PackageInstallState: Equatable, Sendable {
    /// Installer.app is open and the app is not installed yet. The user sees the macOS prompt.
    case waitingForUser
    /// The app bundle exists and the install is not finished. SettleIn infers this state.
    /// Installer.app does not report it.
    case installing
    /// The app bundle exists and the package receipt is new since before the run.
    case installed
    /// The app bundle exists and Installer.app has been closed for three polls in a row. SettleIn saw no new
    /// receipt, so it cannot say that the install finished cleanly.
    case installedAfterInstallerClosed
    /// Installer.app and the app bundle were both absent for enough polls in a row, or the caller cancelled
    /// the task. The poll waits for 3 polls after it has seen Installer.app run, and for 10 when it never did.
    case cancelled
    case failed(PackageInstallFailure)
}

/// Why a package install did not start or did not finish. Each case has a `reason` the UI can show.
public enum PackageInstallFailure: Error, Equatable, Sendable {
    case signature(SignatureFailure)
    case alreadyInstalled
    case notAPackageEntry
    case installerDidNotOpen
    /// The polls that found Installer.app closed added up to the timeout, and the install did not finish.
    case timedOut

    public var reason: String {
        switch self {
        case .signature(let failure):
            return failure.reason
        case .alreadyInstalled:
            return "The app is already installed. SettleIn does not update installed apps yet."
        case .notAPackageEntry:
            return "The catalog entry is not a package, so the package installer cannot install it."
        case .installerDidNotOpen:
            return "SettleIn could not open Installer.app with the package."
        case .timedOut:
            return "The install did not finish in time. If the Installer window is still open, "
                + "finish it there and check the Applications folder."
        }
    }
}
