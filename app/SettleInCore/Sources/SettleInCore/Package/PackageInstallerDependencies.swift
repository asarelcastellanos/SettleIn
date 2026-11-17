import AppKit
import Foundation

/// Checks the signature of a package file against the Team ID the catalog names.
public protocol PackageSignatureChecking: Sendable {
    func verifyPackage(at package: URL, expecting expected: TeamID) async -> SignatureResult
}

extension SignatureVerifier: PackageSignatureChecking {}

/// Finds an installed app by bundle ID. LaunchServices can answer late or with stale data, so callers poll.
public protocol BundleLocator: Sendable {
    func applicationURL(forBundleID bundleID: BundleID) -> URL?
}

/// Asks LaunchServices through `NSWorkspace`.
public struct WorkspaceBundleLocator: BundleLocator {
    public init() {}

    public func applicationURL(forBundleID bundleID: BundleID) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID.rawValue)
    }
}

/// Tells whether Installer.app is running.
public protocol InstallerProcessMonitor: Sendable {
    func isInstallerRunning() -> Bool
}

/// Looks for a running app with the Installer.app bundle ID.
public struct RunningApplicationInstallerMonitor: InstallerProcessMonitor {
    public init() {}

    public func isInstallerRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.installer").isEmpty
    }
}

/// The delay between polls. Tests replace it so they never wait.
public protocol PollingClock: Sendable {
    /// Throws `CancellationError` when the task is cancelled during the delay.
    func sleep(for duration: Duration) async throws
}

public struct SystemPollingClock: PollingClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
