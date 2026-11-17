import Foundation

/// A rule that an uninstall path in the catalog breaks. This type checks the path text only.
/// The runtime symlink check belongs to the uninstaller.
public enum UninstallPathRule: Error, Equatable, Sendable {
    case outsideAllowedRoots
    case isRoot
    case directChildOfLibrary
    case containsParentTraversal
    case containsWildcard
    case malformed
    /// A path under `/Applications` goes inside an `.app` bundle.
    case insideAppBundle
    /// The first folder below `~/Library` is not one of `UninstallPathShape.allowedLibraryFolders`.
    case libraryFolderNotAllowed
    /// A path under `/Applications` is not `/Applications/<Name>.app`.
    case notAnApplication

    init(_ violation: UninstallPathShape.Violation) {
        switch violation {
        case .insideAppBundle: self = .insideAppBundle
        case .libraryFolderNotAllowed: self = .libraryFolderNotAllowed
        case .notAnApplication: self = .notAnApplication
        }
    }
}

/// The rule that a catalog entry broke.
public enum CatalogRule: Equatable, Sendable {
    case notJSON
    case wrongType(field: String)
    case missingField(String)
    case unknownField(String)
    case unexpectedField(String)
    case invalidID(String)
    case duplicateID
    case emptyValue(field: String)
    case unknownInstallType(String)
    case unknownArchitecture(String)
    case invalidAppName(String)
    case invalidPackageIdentifier(String)
    case invalidTeamID(String)
    case invalidBundleID(String)
    case invalidSHA256(String)
    case invalidAllowedHost(String)
    case invalidURL(String)
    case insecureURL(String)
    case hostNotAllowed(host: String, url: String)
    case invalidUninstallPath(path: String, rule: UninstallPathRule)
    /// A pkg entry lists no `/Applications/<Name>.app` path, so the uninstaller could not remove the app.
    case missingApplicationsApp
    case missingSHA256(download: String)
    case unexpectedSHA256(download: String)
    case conflictingSources
}

/// The error that `CatalogParser.parse` throws.
///
/// `appID` is the entry's `id`. An error about the whole file uses `catalog`, and an entry whose
/// `id` is missing or not a string uses its position, such as `apps[2]`.
public struct CatalogError: Error, Equatable, Sendable, CustomStringConvertible {
    public let appID: String
    public let rule: CatalogRule

    public var description: String {
        "catalog entry \(appID): \(rule.message)"
    }
}

extension CatalogRule {
    var message: String {
        switch self {
        case .notJSON: "the file is not valid JSON in the catalog format"
        case .wrongType(let field): "\(field) has the wrong type"
        case .missingField(let field): "\(field) is missing"
        case .unknownField(let field): "\(field) is not a catalog field"
        case .unexpectedField(let field): "\(field) does not apply to this entry"
        case .invalidID(let value): "id \(value) must be lowercase words joined by hyphens"
        case .duplicateID: "the id is used by more than one entry"
        case .emptyValue(let field): "\(field) is empty"
        case .unknownInstallType(let value): "installType \(value) is not dmg, zip, or pkg"
        case .unknownArchitecture(let value): "architecture \(value) is not universal or perArch"
        case .invalidAppName(let value): "appName \(value) must be a folder name that ends in .app"
        case .invalidPackageIdentifier(let value): "pkgIdentifier \(value) is not a package identifier"
        case .invalidTeamID(let value): "teamID \(value) is not 10 uppercase letters or digits"
        case .invalidBundleID(let value): "bundleID \(value) is not a bundle identifier"
        case .invalidSHA256(let value): "sha256 \(value) is not 64 hex characters"
        case .invalidAllowedHost(let value): "allowedHosts entry \(value) is not a lowercase host name"
        case .invalidURL(let value): "\(value) is not a usable URL"
        case .insecureURL(let value): "\(value) does not use https"
        case .hostNotAllowed(let host, let url): "host \(host) of \(url) is not in allowedHosts"
        case .invalidUninstallPath(let path, let rule): "uninstall path \(path) breaks a rule (\(rule))"
        case .missingApplicationsApp: "a pkg entry must list its app as /Applications/<Name>.app in uninstallPaths"
        case .missingSHA256(let download): "a versioned entry needs a sha256 for \(download)"
        case .unexpectedSHA256(let download): "a latest entry must not have a sha256 for \(download)"
        case .conflictingSources: "an entry cannot mix downloadURL or sha256 with arm64 or x86_64"
        }
    }
}
