import Foundation

public enum InstallKind: Equatable, Sendable {
    case dmg
    case zip
}

/// The catalog values that `AppInstaller` needs for one app.
public struct InstallTarget: Equatable, Sendable {
    public let appName: AppBundleName
    public let bundleID: BundleID
    public let teamID: TeamID

    public init(appName: AppBundleName, bundleID: BundleID, teamID: TeamID) {
        self.appName = appName
        self.bundleID = bundleID
        self.teamID = teamID
    }

    /// Returns nil for a `.pkg` entry, which has no app bundle name.
    public init?(catalogApp: CatalogApp) {
        switch catalogApp.install {
        case .dmg(let appName), .zip(let appName):
            self.init(appName: appName, bundleID: catalogApp.bundleID, teamID: catalogApp.teamID)
        case .pkg:
            return nil
        }
    }
}
