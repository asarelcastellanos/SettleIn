import Foundation
import Testing
@testable import SettleInCore

struct CatalogTests {
    /// The repository root. The tests read `catalog/` from the checkout.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SettleInCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // SettleInCore
        .deletingLastPathComponent() // app
        .deletingLastPathComponent() // repository root

    private static func catalogData(_ relativePath: String) throws -> Data {
        try Data(contentsOf: repositoryRoot.appendingPathComponent("catalog").appendingPathComponent(relativePath))
    }

    private static func parseError(fixture name: String) throws -> CatalogError {
        let data = try catalogData("fixtures/invalid/\(name).json")
        do {
            _ = try CatalogParser.parse(data)
        } catch let error as CatalogError {
            return error
        }
        Issue.record("\(name) parsed without an error")
        return CatalogError(appID: "", rule: .notJSON)
    }

    // MARK: Real catalog

    @Test func realCatalogHasThreeApps() throws {
        let catalog = try CatalogParser.parse(Self.catalogData("catalog.json"))
        #expect(catalog.apps.map(\.id) == ["rectangle", "alttab", "google-chrome"])
    }

    @Test func realCatalogInstallTypesAndVersions() throws {
        let apps = try CatalogParser.parse(Self.catalogData("catalog.json")).apps
        guard case .dmg = apps[0].install, case .zip = apps[1].install, case .pkg = apps[2].install else {
            Issue.record("unexpected install types")
            return
        }
        #expect(apps[2].version == .latest)
        guard case .universal(let chrome) = apps[2].source else {
            Issue.record("Chrome should be universal")
            return
        }
        #expect(chrome.sha256 == nil)
    }

    @Test func realCatalogTeamIDsAreTenCharacters() throws {
        let apps = try CatalogParser.parse(Self.catalogData("catalog.json")).apps
        #expect(apps.allSatisfy { $0.teamID.rawValue.count == 10 })
    }

    // MARK: Source forms

    @Test func perArchFixtureParsesIntoPerArchCase() throws {
        let catalog = try CatalogParser.parse(Self.catalogData("fixtures/valid/per-arch.json"))
        guard case .perArch(let arm64, let intel) = catalog.apps[0].source else {
            Issue.record("expected the perArch case")
            return
        }
        #expect(arm64.url.lastPathComponent == "Example-1.2.3-arm64.dmg")
        #expect(intel.url.lastPathComponent == "Example-1.2.3-x86_64.dmg")
        #expect(arm64.sha256 != nil && intel.sha256 != nil)
    }

    @Test func mixedSourceFixtureFails() throws {
        let error = try Self.parseError(fixture: "mixed-source")
        #expect(error == CatalogError(appID: "example", rule: .conflictingSources))
    }

    // MARK: Rejection fixtures

    @Test func unknownInstallTypeFails() throws {
        let error = try Self.parseError(fixture: "unknown-install-type")
        #expect(error == CatalogError(appID: "example", rule: .unknownInstallType("exe")))
    }

    @Test func httpURLFails() throws {
        let error = try Self.parseError(fixture: "http-url")
        #expect(error.appID == "example")
        guard case .insecureURL(let url) = error.rule else {
            Issue.record("wrong rule \(error.rule)")
            return
        }
        #expect(url.hasPrefix("http://"))
    }

    @Test func hostNotOnAllowlistFails() throws {
        let error = try Self.parseError(fixture: "host-not-allowed")
        let url = "https://evil.example.org/Example-1.2.3.dmg"
        #expect(error == CatalogError(appID: "example", rule: .hostNotAllowed(host: "evil.example.org", url: url)))
    }

    @Test func duplicateIDFails() throws {
        let error = try Self.parseError(fixture: "duplicate-id")
        #expect(error == CatalogError(appID: "example", rule: .duplicateID))
    }

    @Test func badTeamIDFails() throws {
        let error = try Self.parseError(fixture: "bad-team-id")
        #expect(error == CatalogError(appID: "example", rule: .invalidTeamID("abcde12345")))
    }

    @Test func badSHA256Fails() throws {
        let error = try Self.parseError(fixture: "bad-sha256")
        #expect(error == CatalogError(appID: "example", rule: .invalidSHA256("1234")))
    }

    @Test func versionedEntryWithoutSHA256Fails() throws {
        let error = try Self.parseError(fixture: "versioned-without-sha256")
        #expect(error == CatalogError(appID: "example", rule: .missingSHA256(download: "downloadURL")))
    }

    @Test func latestEntryWithSHA256Fails() throws {
        let error = try Self.parseError(fixture: "latest-with-sha256")
        #expect(error == CatalogError(appID: "example", rule: .unexpectedSHA256(download: "downloadURL")))
    }

    @Test(arguments: [
        ("path-etc-hosts", "/etc/hosts", UninstallPathRule.outsideAllowedRoots),
        ("path-dotdot", "~/Library/../.ssh", .containsParentTraversal),
        ("path-library-root", "~/Library", .isRoot),
        ("path-library-child", "~/Library/Preferences", .directChildOfLibrary),
        ("path-wildcard", "~/Library/Caches/com.example.*", .containsWildcard),
        ("path-keychains", "~/Library/Keychains/login.keychain-db", .libraryFolderNotAllowed),
        ("path-icloud-drive", "~/Library/Mobile Documents/com~apple~CloudDocs/Documents", .libraryFolderNotAllowed),
        ("path-inside-app", "/Applications/Example.app/Contents/MacOS/Example", .insideAppBundle),
        ("path-applications-deep", "/Applications/Utilities/Example.app", .notAnApplication)
    ])
    func badUninstallPathFails(fixture: String, path: String, rule: UninstallPathRule) throws {
        let error = try Self.parseError(fixture: fixture)
        #expect(error == CatalogError(appID: "example", rule: .invalidUninstallPath(path: path, rule: rule)))
    }

    @Test func pkgEntryWithoutAnApplicationsAppFails() throws {
        let error = try Self.parseError(fixture: "pkg-without-app")
        #expect(error == CatalogError(appID: "example", rule: .missingApplicationsApp))
        #expect(error.description.contains("/Applications/<Name>.app"))
    }

    @Test func badAppNameFails() throws {
        let error = try Self.parseError(fixture: "bad-app-name")
        #expect(error == CatalogError(appID: "example", rule: .invalidAppName("../Evil.app")))
    }

    @Test func realCatalogPkgEntryListsItsApplicationsApp() throws {
        let apps = try CatalogParser.parse(Self.catalogData("catalog.json")).apps
        let chrome = try #require(apps.first { $0.id == "google-chrome" })
        #expect(chrome.uninstallPaths.contains { $0.rawValue == "/Applications/Google Chrome.app" })
    }

    @Test func errorNamesTheAppAndTheRule() throws {
        let error = try Self.parseError(fixture: "bad-team-id")
        #expect(error.description.contains("example"))
        #expect(error.description.contains("teamID"))
    }

    // MARK: Inline cases

    private static func parse(_ json: String) throws -> Catalog {
        try CatalogParser.parse(Data(json.utf8))
    }

    @Test func fileThatIsNotJSONFails() {
        #expect(throws: CatalogError(appID: "catalog", rule: .notJSON)) {
            try Self.parse("not json")
        }
    }

    @Test func emptyCatalogParsesToNoApps() throws {
        #expect(try Self.parse(#"{"apps": []}"#).apps.isEmpty)
    }

    @Test func unknownTopLevelKeyFails() {
        #expect(throws: CatalogError(appID: "catalog", rule: .unknownField("extra"))) {
            try Self.parse(#"{"apps": [], "extra": 1}"#)
        }
    }

    @Test func entryWithoutIDIsNamedByPosition() {
        #expect(throws: CatalogError(appID: "apps[0]", rule: .missingField("id"))) {
            try Self.parse(#"{"apps": [{}]}"#)
        }
    }

    // MARK: Value types

    @Test(arguments: ["ABCDE12345", "XSYZ3E4B7D", "0123456789"])
    func teamIDAcceptsTenUppercaseCharacters(raw: String) {
        #expect(TeamID(raw)?.rawValue == raw)
    }

    @Test(arguments: ["", "ABCDE1234", "ABCDE123456", "abcde12345", "ABCDE1234\n", "ABCDE-2345", "ABCDE1234É"])
    func teamIDRejectsOtherText(raw: String) {
        #expect(TeamID(raw) == nil)
    }

    @Test func sha256AcceptsSixtyFourHexCharactersAndLowercasesThem() {
        let upper = String(repeating: "AB", count: 32)
        #expect(SHA256Digest(upper)?.rawValue == String(repeating: "ab", count: 32))
    }

    @Test(arguments: ["", "abc", String(repeating: "g", count: 64), String(repeating: "a", count: 65)])
    func sha256RejectsOtherText(raw: String) {
        #expect(SHA256Digest(raw) == nil)
    }

    @Test(arguments: ["github.com", "release-assets.githubusercontent.com", "dl.google.com"])
    func allowedHostAcceptsHostNames(raw: String) {
        #expect(AllowedHost(raw)?.rawValue == raw)
    }

    @Test(arguments: ["", "localhost", "GitHub.com", "*.github.com", "github.com/path", "a..com", "-a.com", "https://github.com"])
    func allowedHostRejectsOtherText(raw: String) {
        #expect(AllowedHost(raw) == nil)
    }

    @Test(arguments: ["com.example.App", "com.lwouis.alt-tab-macos"])
    func bundleIDAcceptsReverseDNSNames(raw: String) {
        #expect(BundleID(raw)?.rawValue == raw)
    }

    @Test(arguments: ["", "App", "com..App", "com.example.App\n", "com.exa mple.App"])
    func bundleIDRejectsOtherText(raw: String) {
        #expect(BundleID(raw) == nil)
    }

    @Test(arguments: [
        "/Applications/Example.app",
        "~/Library/Application Support/Example",
        "~/Library/Preferences/com.example.App.plist",
        "~/Library/Caches/Vendor/Example",
        "~/Library/Logs/Example/run.log",
        "~/Library/Containers/com.example.App",
        "~/Library/Saved Application State/com.example.App.savedState",
        "~/Library/HTTPStorages/com.example.App",
        "~/Library/WebKit/com.example.App",
        "~/Library/Cookies/com.example.App.binarycookies",
        "~/Library/Application Support/Vendor/Listed.app",
        "~/Library/Containers/com.vendor.app/Data/Library/Caches",
        "~/Library/Caches/com.vendor.app",
        "~/Library/Application Support/Example.app/Contents/Resources/x",
        "~/.config/tool.app/settings.toml",
        "~/.config/example",
        "~/.config/example/settings.toml"
    ])
    func uninstallPathAcceptsAllowedPaths(raw: String) throws {
        #expect(try UninstallPath(raw).rawValue == raw)
    }

    @Test(arguments: [
        ("/Applications", UninstallPathRule.isRoot),
        ("~/.config", .isRoot),
        ("/Applications/../etc", .containsParentTraversal),
        ("/Applications/*.app", .containsWildcard),
        ("~/Library/Caches/[a]", .containsWildcard),
        ("/Library/Preferences/x.plist", .outsideAllowedRoots),
        ("~/Documents/x", .outsideAllowedRoots),
        ("Applications/x", .outsideAllowedRoots),
        ("/Applications/", .malformed),
        ("~/Library/Caches/", .malformed),
        ("~/Library//Caches/x", .malformed),
        ("~/Library/Caches/./x", .malformed),
        ("/Applications/Ex\nample.app", .malformed),
        ("/Applications/Example.app/Contents/MacOS/x", .insideAppBundle),
        ("/Applications/Example.APP/Contents", .insideAppBundle),
        ("/Applications/Utilities/Example.app", .notAnApplication),
        ("/Applications/Example", .notAnApplication),
        ("/Applications/.app", .notAnApplication),
        ("~/Library/Keychains/login.keychain-db", .libraryFolderNotAllowed),
        ("~/Library/Mobile Documents/com~apple~CloudDocs/x", .libraryFolderNotAllowed),
        ("~/Library/Mail/V10/x", .libraryFolderNotAllowed),
        ("~/Library/caches/x", .libraryFolderNotAllowed),
        ("~/Library/LaunchAgents/com.example.plist", .libraryFolderNotAllowed)
    ])
    func uninstallPathRejectsBrokenPaths(raw: String, rule: UninstallPathRule) {
        #expect(throws: rule) {
            try UninstallPath(raw)
        }
    }
}
