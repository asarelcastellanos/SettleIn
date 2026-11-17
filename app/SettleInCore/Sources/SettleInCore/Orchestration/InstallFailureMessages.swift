import Foundation

// Messages for the engine errors. Each switch is exhaustive. None of them prints a `detail` string,
// because that text comes from tool output or from a downloaded file.

extension DownloadError {
    var message: String {
        switch self {
        case .insecureScheme:
            "SettleIn refused the download because its address does not use https."
        case .disallowedHost(let host):
            "SettleIn refused the download because the host \(host) is not on the app's allowed list."
        case .disallowedRedirect:
            "The download server sent SettleIn to a host that is not on the allowed list, so SettleIn stopped."
        case .unexpectedStatus(let status):
            "The download server answered with status \(status) instead of 200."
        case .digestMismatch:
            "The downloaded file does not match the SHA-256 in the catalog, so SettleIn deleted it "
                + "and installed nothing."
        case .transferFailed(let code):
            "The download failed with network error code \(code)."
        case .fileWriteFailed:
            "SettleIn could not write the download to disk."
        case .privateDirectoryFailed:
            "SettleIn could not create a private folder for the download."
        }
    }
}

extension InstallError {
    var message: String {
        switch self {
        case .destinationNotWritable(let path):
            "SettleIn cannot write to \(path)."
        case .workingDirectoryFailed:
            "SettleIn could not create a private working folder for the install."
        case .mountTimedOut:
            "The disk image did not open within 60 seconds. It may show a license agreement, "
                + "which SettleIn cannot accept for you."
        case .mountFailed:
            "SettleIn could not open the disk image."
        case .extractFailed:
            "SettleIn could not unpack the zip file."
        case .unsafeArchiveItem:
            "The archive holds an item that points outside its own folder, so SettleIn installed nothing."
        case .appNotFound(let name):
            "The archive does not contain \(name)."
        case .freeSpaceUnreadable(let path):
            "SettleIn could not read the free space on the volume that holds \(path)."
        case .notEnoughSpace(let needed, let available):
            "The install needs \(Self.size(needed)) of free space, and the volume has \(Self.size(available))."
        case .signatureInvalid(let failure):
            failure.message
        case .bundleIDMismatch(let expected):
            "The app in the archive does not have the bundle ID \(expected) that the catalog names, "
                + "so SettleIn installed nothing."
        case .differentAppAtDestination(let path):
            "A different app is already at \(path), so SettleIn left it alone."
        case .replaceDeclined:
            "The existing app was not replaced."
        case .quitDeclined:
            "The app is running and was not asked to quit, so SettleIn did not replace it."
        case .appStillRunning:
            "The app is still running, so SettleIn did not replace it. Quit the app and try again."
        case .copyFailed:
            "SettleIn could not copy the app into place."
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension SignatureFailure {
    var message: String {
        switch self {
        case .unsigned:
            "The file is not signed, so SettleIn cannot tell who made it. SettleIn installed nothing."
        case .brokenSignature:
            "The signature is not valid, so SettleIn installed nothing."
        case .gatekeeperRejected:
            "macOS Gatekeeper rejected the app, so SettleIn installed nothing."
        case .teamIDMissing:
            "The signature has no Team ID, so SettleIn installed nothing."
        case .teamIDMismatch(let expected, let actual):
            "The signature belongs to Team ID \(actual), but the catalog expects Team ID \(expected). "
                + "SettleIn installed nothing."
        case .toolFailed(let tool, let exitCode):
            exitCode == Self.toolDidNotStart
                ? "SettleIn could not start the \(tool) tool, so it could not check the signature."
                : "The \(tool) tool failed with exit code \(exitCode), so SettleIn could not check the signature."
        }
    }
}

extension PackageInstallFailure {
    var message: String {
        switch self {
        case .signature(let failure):
            failure.message
        case .alreadyInstalled:
            "The app is already installed. SettleIn does not update installed apps yet."
        case .notAPackageEntry:
            "The catalog entry is not a package, so the package installer cannot install it."
        case .installerDidNotOpen:
            "SettleIn could not open Installer.app with the package."
        case .timedOut:
            "The install did not finish in time. If the Installer window is still open, "
                + "finish it there and check the Applications folder."
        }
    }
}

extension UninstallError {
    var message: String {
        switch self {
        case .quitDeclined:
            "The app is running and was not asked to quit, so SettleIn removed nothing."
        case .appStillRunning:
            "The app is still running, so SettleIn removed nothing. Quit the app and try again."
        }
    }
}
