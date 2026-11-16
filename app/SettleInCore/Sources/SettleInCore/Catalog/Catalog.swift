import Foundation

/// A parsed catalog. Every value in it passed the rules in `CatalogParser`.
public struct Catalog: Equatable, Sendable {
    public let apps: [CatalogApp]
}

public enum CatalogVersion: Equatable, Sendable {
    /// The vendor's newest build. The entry has no SHA-256 and relies on the Team ID check.
    case latest
    /// A specific release. Every download of the entry has a SHA-256.
    case pinned(String)
}

public enum InstallMethod: Equatable, Sendable {
    case dmg(appName: AppBundleName)
    case zip(appName: AppBundleName)
    case pkg(identifier: PackageIdentifier)
}

public struct CatalogDownload: Equatable, Sendable {
    public let url: URL
    public let sha256: SHA256Digest?
}

/// Where an app's files come from. One entry holds one form, never both. `intel` is the `x86_64` build.
public enum DownloadSource: Equatable, Sendable {
    case universal(CatalogDownload)
    case perArch(arm64: CatalogDownload, intel: CatalogDownload)
}

public struct CatalogApp: Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: String
    public let homepage: URL
    public let version: CatalogVersion
    public let install: InstallMethod
    public let allowedHosts: [AllowedHost]
    public let teamID: TeamID
    public let bundleID: BundleID
    public let uninstallPaths: [UninstallPath]
    public let source: DownloadSource
}
