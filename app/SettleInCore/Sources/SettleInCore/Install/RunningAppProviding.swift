import AppKit
import Foundation

/// Reports whether an app is running and asks it to quit. The installer uses it before it replaces an app,
/// and the uninstaller will use it before it removes one.
public protocol RunningAppProviding: Sendable {
    func isRunning(bundleID: BundleID) -> Bool

    /// Asks every running copy of the app to quit and waits up to `timeout`. Returns true when none is left.
    /// An implementation never forces the app to quit.
    func terminate(bundleID: BundleID, timeout: Duration) async -> Bool
}

/// Looks up running apps with `NSRunningApplication`.
public struct WorkspaceRunningApps: RunningAppProviding {
    public init() {}

    public func isRunning(bundleID: BundleID) -> Bool {
        !instances(of: bundleID).isEmpty
    }

    public func terminate(bundleID: BundleID, timeout: Duration) async -> Bool {
        for instance in instances(of: bundleID) {
            _ = instance.terminate()
        }
        let deadline = ContinuousClock.now + timeout
        while !instances(of: bundleID).isEmpty {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private func instances(of bundleID: BundleID) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID.rawValue).filter { !$0.isTerminated }
    }
}
