import Foundation

/// Why an install failed. Each case has a message the UI can show.
/// Cancelling the Swift task throws `CancellationError`, not an `InstallError`.
public enum InstallError: Error, Equatable, Sendable, LocalizedError {
    /// The destination folder is missing, is not a folder, or the current user cannot write to it.
    case destinationNotWritable(path: String)
    case workingDirectoryFailed
    /// `hdiutil attach` did not finish in time. A license agreement inside the image causes this.
    case mountTimedOut
    case mountFailed(detail: String)
    case extractFailed(detail: String)
    /// An item in the archive resolves to a path outside the extract folder.
    case unsafeArchiveItem(path: String)
    case appNotFound(name: String)
    case freeSpaceUnreadable(path: String)
    case notEnoughSpace(needed: Int64, available: Int64)
    case signatureInvalid(SignatureFailure)
    /// The signature of the staged copy is valid, but its `CFBundleIdentifier` is not the catalog bundle ID.
    case bundleIDMismatch(expected: String)
    /// An app with the same file name but another bundle ID is already at the destination.
    case differentAppAtDestination(path: String)
    /// The user answered no when asked to replace the installed app.
    case replaceDeclined
    /// The user answered no when asked to quit the running app.
    case quitDeclined
    /// The app did not quit, or it was still running after the wait.
    case appStillRunning
    case copyFailed(detail: String)

    public var errorDescription: String? {
        switch self {
        case .destinationNotWritable(let path):
            return "SettleIn cannot write to \(path). Choose a folder you can write to. "
                + "SettleIn does not ask for a password."
        case .workingDirectoryFailed:
            return "SettleIn could not create a private working folder for the install."
        case .mountTimedOut:
            return "The disk image did not open within 60 seconds. It may show a license agreement, "
                + "which SettleIn cannot accept for you."
        case .mountFailed(let detail):
            return "SettleIn could not open the disk image. \(detail)"
        case .extractFailed(let detail):
            return "SettleIn could not unpack the zip file. \(detail)"
        case .unsafeArchiveItem(let path):
            return "The archive holds an item that points outside its own folder (\(path)). "
                + "SettleIn installed nothing."
        case .appNotFound(let name):
            return "The archive does not contain \(name)."
        case .freeSpaceUnreadable(let path):
            return "SettleIn could not read the free space on the volume that holds \(path)."
        case .notEnoughSpace(let needed, let available):
            let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            return "The install needs \(format(needed)) of free space, and the volume has \(format(available))."
        case .signatureInvalid(let failure):
            return failure.reason
        case .bundleIDMismatch(let expected):
            return "The app in the archive does not have the bundle ID \(expected) that the catalog names. "
                + "SettleIn installed nothing."
        case .differentAppAtDestination(let path):
            return "A different app is already at \(path). SettleIn left it alone."
        case .replaceDeclined:
            return "The existing app was not replaced."
        case .quitDeclined:
            return "The app is running and was not asked to quit, so SettleIn did not replace it."
        case .appStillRunning:
            return "The app is still running, so SettleIn did not replace it. Quit the app and try again."
        case .copyFailed(let detail):
            return "SettleIn could not copy the app. \(detail)"
        }
    }
}
