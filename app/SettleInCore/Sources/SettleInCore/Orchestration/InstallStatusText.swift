import Foundation

extension InstallState {
    /// True while a pkg row waits for Installer.app. The row then offers a way out, because SettleIn cannot
    /// tell when the user has walked away from the Installer window.
    public func canStopWaiting(for install: InstallMethod) -> Bool {
        if case .installing = self, case .pkg = install { return true }
        return false
    }

    /// The status line of an app's row. The text depends on the install type, because the same state covers
    /// different work.
    ///
    /// A dmg or zip passes `verifying` while the installer checks the signature and copies the app, since
    /// the installer does both inside one call. A pkg passes `installing` while SettleIn polls for the app
    /// that Installer.app installs.
    public func statusText(for install: InstallMethod) -> String {
        let isPackage = if case .pkg = install { true } else { false }
        switch self {
        case .idle: return "Not installed"
        case .downloading(let progress): return progress.map { "Downloading, \(Int($0 * 100))%" } ?? "Downloading"
        case .verifying: return isPackage ? "Verifying" : "Checking and installing"
        case .installing: return isPackage ? "Waiting for Installer" : "Installing"
        case .installed: return "Installed"
        case .uninstalling: return "Uninstalling"
        case .failed: return "Failed"
        }
    }
}
