import Foundation

/// The one entry point that turns catalog bytes into a `Catalog`.
///
/// This is the boundary. It checks every rule once, and the rest of the app trusts the types it returns.
public enum CatalogParser {
    public static func parse(_ data: Data) throws -> Catalog {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError(appID: "catalog", rule: .notJSON)
        }
        let fields = Fields(appID: "catalog", object: root)
        if let unknown = root.keys.sorted().first(where: { $0 != "apps" }) {
            throw fields.error(.unknownField(unknown))
        }
        guard let entries = try fields.array("apps") else { throw fields.error(.missingField("apps")) }

        var seenIDs = Set<String>()
        var apps: [CatalogApp] = []
        for (index, entry) in entries.enumerated() {
            apps.append(try parseApp(entry, label: "apps[\(index)]", seenIDs: &seenIDs))
        }
        return Catalog(apps: apps)
    }

    private static let appKeys: Set<String> = [
        "id", "name", "category", "homepage", "version", "installType", "appName", "pkgIdentifier",
        "allowedHosts", "teamID", "bundleID", "uninstallPaths", "architecture",
        "downloadURL", "sha256", "arm64", "x86_64"
    ]

    private static func parseApp(_ entry: Any, label: String, seenIDs: inout Set<String>) throws -> CatalogApp {
        guard let object = entry as? [String: Any] else {
            throw CatalogError(appID: label, rule: .wrongType(field: "apps entry"))
        }
        let id = try Fields(appID: label, object: object).string("id")
        let fields = Fields(appID: id, object: object)
        guard isValidID(id) else { throw fields.error(.invalidID(id)) }
        guard seenIDs.insert(id).inserted else { throw fields.error(.duplicateID) }
        if let unknown = object.keys.sorted().first(where: { !appKeys.contains($0) }) {
            throw fields.error(.unknownField(unknown))
        }

        let allowedHosts = try parseAllowedHosts(fields)
        let version = try parseVersion(fields)
        return CatalogApp(
            id: id,
            name: try fields.nonEmptyString("name"),
            category: try fields.nonEmptyString("category"),
            homepage: try parseURL(fields.string("homepage"), fields: fields),
            version: version,
            install: try parseInstall(fields),
            allowedHosts: allowedHosts,
            teamID: try parseTeamID(fields),
            bundleID: try parseBundleID(fields),
            uninstallPaths: try parseUninstallPaths(fields),
            source: try parseSource(fields, version: version, allowedHosts: allowedHosts)
        )
    }

    private static func isValidID(_ id: String) -> Bool {
        let words = id.split(separator: "-", omittingEmptySubsequences: false)
        return !words.isEmpty && words.allSatisfy { word in
            !word.isEmpty && word.unicodeScalars.allSatisfy { scalar in
                (0x61...0x7A).contains(scalar.value) || (0x30...0x39).contains(scalar.value)
            }
        }
    }

    private static func parseVersion(_ fields: Fields) throws -> CatalogVersion {
        let version = try fields.nonEmptyString("version")
        return version == "latest" ? .latest : .pinned(version)
    }

    private static func parseInstall(_ fields: Fields) throws -> InstallMethod {
        let installType = try fields.string("installType")
        switch installType {
        case "dmg", "zip":
            if fields.has("pkgIdentifier") { throw fields.error(.unexpectedField("pkgIdentifier")) }
            let raw = try fields.string("appName")
            guard let appName = AppBundleName(raw) else { throw fields.error(.invalidAppName(raw)) }
            return installType == "dmg" ? .dmg(appName: appName) : .zip(appName: appName)
        case "pkg":
            if fields.has("appName") { throw fields.error(.unexpectedField("appName")) }
            let raw = try fields.string("pkgIdentifier")
            guard let identifier = PackageIdentifier(raw) else { throw fields.error(.invalidPackageIdentifier(raw)) }
            return .pkg(identifier: identifier)
        default:
            throw fields.error(.unknownInstallType(installType))
        }
    }

    private static func parseTeamID(_ fields: Fields) throws -> TeamID {
        let raw = try fields.string("teamID")
        guard let teamID = TeamID(raw) else { throw fields.error(.invalidTeamID(raw)) }
        return teamID
    }

    private static func parseBundleID(_ fields: Fields) throws -> BundleID {
        let raw = try fields.string("bundleID")
        guard let bundleID = BundleID(raw) else { throw fields.error(.invalidBundleID(raw)) }
        return bundleID
    }

    private static func parseAllowedHosts(_ fields: Fields) throws -> [AllowedHost] {
        try fields.stringArray("allowedHosts").map { raw in
            guard let host = AllowedHost(raw) else { throw fields.error(.invalidAllowedHost(raw)) }
            return host
        }
    }

    private static func parseUninstallPaths(_ fields: Fields) throws -> [UninstallPath] {
        try fields.stringArray("uninstallPaths").map { raw in
            do {
                return try UninstallPath(raw)
            } catch let rule as UninstallPathRule {
                throw fields.error(.invalidUninstallPath(path: raw, rule: rule))
            }
        }
    }

    private static func parseSource(
        _ fields: Fields,
        version: CatalogVersion,
        allowedHosts: [AllowedHost]
    ) throws -> DownloadSource {
        let rules = DownloadRules(pinned: version != .latest, allowedHosts: allowedHosts)
        let architecture = try fields.string("architecture")
        switch architecture {
        case "universal":
            if fields.has("arm64") || fields.has("x86_64") { throw fields.error(.conflictingSources) }
            return .universal(try parseDownload(fields, label: "downloadURL", rules: rules))
        case "perArch":
            if fields.has("downloadURL") || fields.has("sha256") { throw fields.error(.conflictingSources) }
            return .perArch(
                arm64: try parseDownload(try fields.nested("arm64"), label: "arm64", rules: rules),
                intel: try parseDownload(try fields.nested("x86_64"), label: "x86_64", rules: rules)
            )
        default:
            throw fields.error(.unknownArchitecture(architecture))
        }
    }

    private static func parseDownload(
        _ fields: Fields,
        label: String,
        rules: DownloadRules
    ) throws -> CatalogDownload {
        let url = try parseURL(fields.string("downloadURL"), fields: fields)
        guard rules.allowedHosts.contains(where: { $0.matches(url) }) else {
            throw fields.error(.hostNotAllowed(host: url.host(percentEncoded: false) ?? "", url: url.absoluteString))
        }
        let sha256 = try fields.optionalString("sha256").map { raw in
            guard let digest = SHA256Digest(raw) else { throw fields.error(.invalidSHA256(raw)) }
            return digest
        }
        if rules.pinned, sha256 == nil { throw fields.error(.missingSHA256(download: label)) }
        if !rules.pinned, sha256 != nil { throw fields.error(.unexpectedSHA256(download: label)) }
        return CatalogDownload(url: url, sha256: sha256)
    }

    private static func parseURL(_ raw: String, fields: Fields) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme, url.host != nil else {
            throw fields.error(.invalidURL(raw))
        }
        guard scheme == "https" else { throw fields.error(.insecureURL(raw)) }
        guard url.user == nil, url.password == nil else { throw fields.error(.invalidURL(raw)) }
        return url
    }
}

/// What a download must satisfy, taken from the entry it belongs to.
private struct DownloadRules {
    let pinned: Bool
    let allowedHosts: [AllowedHost]
}

/// One JSON object plus the entry id used in errors.
private struct Fields {
    let appID: String
    let object: [String: Any]

    func error(_ rule: CatalogRule) -> CatalogError {
        CatalogError(appID: appID, rule: rule)
    }

    func has(_ key: String) -> Bool {
        object[key] != nil
    }

    func string(_ key: String) throws -> String {
        guard let value = object[key] else { throw error(.missingField(key)) }
        guard let string = value as? String else { throw error(.wrongType(field: key)) }
        return string
    }

    func nonEmptyString(_ key: String) throws -> String {
        let value = try string(key)
        guard !value.isEmpty else { throw error(.emptyValue(field: key)) }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        has(key) ? try string(key) : nil
    }

    func array(_ key: String) throws -> [Any]? {
        guard let value = object[key] else { return nil }
        guard let array = value as? [Any] else { throw error(.wrongType(field: key)) }
        return array
    }

    func stringArray(_ key: String) throws -> [String] {
        guard let array = try array(key) else { throw error(.missingField(key)) }
        return try array.map { element in
            guard let string = element as? String else { throw error(.wrongType(field: key)) }
            return string
        }
    }

    func nested(_ key: String) throws -> Fields {
        guard let value = object[key] else { throw error(.missingField(key)) }
        guard let nested = value as? [String: Any] else { throw error(.wrongType(field: key)) }
        if let unknown = nested.keys.sorted().first(where: { $0 != "downloadURL" && $0 != "sha256" }) {
            throw error(.unknownField("\(key).\(unknown)"))
        }
        return Fields(appID: appID, object: nested)
    }
}
