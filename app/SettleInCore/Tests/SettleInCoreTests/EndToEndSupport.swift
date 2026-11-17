import Foundation
import Testing
@testable import SettleInCore

/// End-to-end tests. They build the fixtures with `Tests/Fixtures/build-fixtures.sh`, serve them through a
/// `URLProtocol` stub to the real `Downloader`, and run the real `hdiutil`, `ditto`, `codesign`, `pkgutil`,
/// `AppInstaller`, and `Uninstaller` inside a temp folder that stands in for the home folder and for
/// `/Applications`. The Team ID comparison uses a stub, because an ad hoc signed fixture has no Team ID.
/// The pkg flow uses the fake runner, so Installer.app never opens and no password is ever needed.
///
/// The tests run one at a time because they share `hdiutil` and the machine's load.
@Suite("IntegrationTests", .serialized)
struct IntegrationTests {}

enum FixtureKind {
    case dmg, zip, pkg

    var fileExtension: String {
        switch self {
        case .dmg: "dmg"
        case .zip: "zip"
        case .pkg: "pkg"
        }
    }
}

/// How the stub ends a transfer.
enum Delivery {
    case complete
    /// Sends half of the file, then fails with `networkConnectionLost`.
    case dropsHalfway
}

/// Everything one end-to-end test touches, all under one temp folder.
struct EndToEndWorld {
    static let host = "downloads.example.com"
    static let bundleID = "com.example.SettleInFixture"
    static let expectedTeam = teamID("ABCDE12345")
    static let quarantineValue = "0083;00000000;Test;"

    let sandbox: UninstallSandbox
    let install: InstallSandbox
    let fixtures: URL
    let downloads: URL
    let trash: FakeTrash
    private let token = UUID().uuidString

    var applications: URL { sandbox.applications }
    var home: URL { sandbox.home }
    var fixtureApp: URL { fixtures.appendingPathComponent("Fixture.app", isDirectory: true) }

    func fixture(_ kind: FixtureKind) -> URL {
        fixtures.appendingPathComponent("Fixture.\(kind.fileExtension)")
    }

    static func make() async throws -> EndToEndWorld {
        let sandbox = try UninstallSandbox.make()
        let install = InstallSandbox(
            root: sandbox.root,
            destination: sandbox.applications,
            temporaryRoot: sandbox.root.appendingPathComponent("tmp", isDirectory: true),
            sources: sandbox.root.appendingPathComponent("sources", isDirectory: true)
        )
        let downloads = sandbox.root.appendingPathComponent("downloads", isDirectory: true)
        let fixtures = sandbox.root.appendingPathComponent("fixtures", isDirectory: true)
        for folder in [install.temporaryRoot, install.sources, downloads] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        do {
            try await SharedFixtures.copy(to: fixtures)
        } catch {
            sandbox.cleanUp()
            throw error
        }
        return EndToEndWorld(
            sandbox: sandbox, install: install, fixtures: fixtures, downloads: downloads,
            trash: FakeTrash(folder: sandbox.trashFolder)
        )
    }

    /// Fails the test when an image from this world is still attached, then removes the world.
    func cleanUp() async {
        EndToEndStub.remove(prefix: "https://\(Self.host)/\(token)/")
        await install.cleanUp()
    }

    /// Names left in the downloader's folder and in the installer's working folder. Both must be empty.
    var leftovers: [String] {
        install.entries(in: downloads) + install.entries(in: install.temporaryRoot)
    }

    var installedApps: [String] { install.entries(in: applications) }

    var target: InstallTarget {
        guard let name = AppBundleName("Fixture.app"), let bundle = BundleID(Self.bundleID) else {
            fatalError("bad fixture literal")
        }
        return InstallTarget(appName: name, bundleID: bundle, teamID: Self.expectedTeam)
    }

    // MARK: Catalog entry and stub server

    /// A catalog entry for one fixture. The stub serves the fixture at the entry's URL, and the entry pins
    /// the fixture's real SHA-256 unless the test passes another one.
    func catalogApp(_ kind: FixtureKind, delivery: Delivery = .complete, sha256: String? = nil) throws -> CatalogApp {
        let file = fixture(kind)
        let urlText = "https://\(Self.host)/\(token)/Fixture.\(kind.fileExtension)"
        EndToEndStub.serve(try Data(contentsOf: file), dropsHalfway: delivery == .dropsHalfway, at: urlText)
        guard
            let url = URL(string: urlText),
            let digest = try SHA256Digest(sha256 ?? FileDigest.sha256(of: file).rawValue),
            let name = AppBundleName("Fixture.app"),
            let bundle = BundleID(Self.bundleID),
            let identifier = PackageIdentifier(Self.bundleID + ".pkg"),
            let host = AllowedHost(Self.host)
        else { fatalError("bad fixture literal") }
        let install: InstallMethod
        switch kind {
        case .dmg: install = .dmg(appName: name)
        case .zip: install = .zip(appName: name)
        case .pkg: install = .pkg(identifier: identifier)
        }
        return CatalogApp(
            id: "fixture", name: "Fixture", category: "Tools", homepage: url, version: .pinned("1.0"),
            install: install, allowedHosts: [host], teamID: Self.expectedTeam, bundleID: bundle,
            uninstallPaths: try Self.uninstallPaths.map { try UninstallPath($0) },
            source: .universal(CatalogDownload(url: url, sha256: digest))
        )
    }

    /// The entry omits `/Applications/Fixture.app`. The uninstaller removes the app through its own
    /// applications folder, which is a temp folder here. The text `/Applications/...` would name the real folder,
    /// which the path guard refuses when the roots are temp folders.
    static let uninstallPaths = [
        "~/Library/Application Support/SettleInFixture",
        "~/Library/Preferences/com.example.SettleInFixture.plist"
    ]

    /// Writes the support files that the catalog entry lists, so an uninstall has something to remove.
    func seedSupportFiles() throws {
        try sandbox.makeFolder(sandbox.support.appendingPathComponent("SettleInFixture", isDirectory: true))
        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try "prefs".write(
            to: preferences.appendingPathComponent("com.example.SettleInFixture.plist"),
            atomically: true, encoding: .utf8
        )
    }

    /// Puts an app with the fixture's bundle ID, or another one, at the destination. Its `CFBundleName` is
    /// `Test`, so a test can tell it from the installed fixture, whose name is `Fixture`.
    @discardableResult
    func preinstall(bundleID: String = EndToEndWorld.bundleID) throws -> URL {
        try sandbox.makeApp(named: "Fixture.app", bundleID: bundleID)
    }

    // MARK: Wiring

    func makeOrchestrator(
        installer: AppInstaller? = nil,
        package: any PackageInstalling = FakePackageInstaller(),
        uninstaller: Uninstaller? = nil,
        installedBundleIDs: Set<String> = []
    ) -> (orchestrator: InstallOrchestrator, states: StateRecorder) {
        let orchestrator = InstallOrchestrator(
            downloader: Downloader(configuration: EndToEndStub.configuration(), temporaryRoot: downloads),
            appInstaller: installer ?? AppInstaller.testing(install, checker: .passing(Self.expectedTeam)),
            packageInstaller: package,
            uninstaller: uninstaller ?? Uninstaller.testing(sandbox, trash: trash),
            locator: FakeBundleLocator(found: installedBundleIDs),
            architecture: .arm64,
            homeDirectory: home.path
        )
        return (orchestrator, StateRecorder(orchestrator))
    }

    func quarantine(_ file: URL) async throws {
        let result = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-w", "com.apple.quarantine", Self.quarantineValue, file.path]
        )
        try #require(result.exitCode == 0, "xattr failed: \(result.stderr)")
    }

    func quarantineValue(of file: URL) async throws -> String? {
        let result = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-p", "com.apple.quarantine", file.path]
        )
        return result.exitCode == 0 ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}

enum EndToEndError: Error {
    case fixtureBuildFailed(String)
}

/// Runs `body` with a fresh world and cleans it up on every exit path.
func withEndToEndWorld(_ body: (EndToEndWorld) async throws -> Void) async throws {
    let world = try await EndToEndWorld.make()
    do {
        try await body(world)
    } catch {
        await world.cleanUp()
        throw error
    }
    await world.cleanUp()
}

/// The failure of an operation that ended in `failed`.
func failure(of outcome: OperationOutcome) -> InstallFailure? {
    guard case .completed(.failed(let failure)) = outcome else { return nil }
    return failure
}

/// The state names in order, without repeats, so progress ticks do not matter.
func collapsed(_ names: [String]) -> [String] {
    names.enumerated().filter { $0.offset == 0 || names[$0.offset - 1] != $0.element }.map(\.element)
}

func infoValue(_ key: String, of app: URL) -> String? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return info[key] as? String
}

// MARK: Stub server

/// Serves bytes for the real `Downloader`. Each world serves under its own random path, so tests do not
/// share routes and the stub needs no reset.
enum EndToEndStub {
    struct Route {
        let data: Data
        let dropsHalfway: Bool
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]

    static func serve(_ data: Data, dropsHalfway: Bool, at url: String) {
        lock.withLock { routes[url] = Route(data: data, dropsHalfway: dropsHalfway) }
    }

    static func remove(prefix: String) {
        lock.withLock { routes = routes.filter { !$0.key.hasPrefix(prefix) } }
    }

    fileprivate static func route(for url: URL) -> Route? {
        lock.withLock { routes[url.absoluteString] }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EndToEndStubProtocol.self]
        return configuration
    }
}

final class EndToEndStubProtocol: URLProtocol {
    private static let chunkSize = 16 * 1024

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let route = EndToEndStub.route(for: url),
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(route.data.count)]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let sent = route.dropsHalfway ? route.data.prefix(route.data.count / 2) : route.data[...]
        var offset = sent.startIndex
        while offset < sent.endIndex {
            let end = min(offset + Self.chunkSize, sent.endIndex)
            client?.urlProtocol(self, didLoad: Data(sent[offset..<end]))
            offset = end
        }
        if route.dropsHalfway {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: Shared fixtures

nonisolated(unsafe) private var sharedFixturesExitPath: String?

/// Builds the fixtures once for the whole test run, so the run calls `hdiutil create` once and not once per
/// test, then hands each test its own copy. The folder is removed when the test process exits.
enum SharedFixtures {
    private static let build = FixtureBuild()

    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SettleInCoreTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/build-fixtures.sh")

    /// Copies the built fixtures into `destination` with `ditto`, which keeps the signature and the attributes.
    static func copy(to destination: URL) async throws {
        let source = try await build.folder(script: script)
        let copied = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [source.path, destination.path]
        )
        guard copied.exitCode == 0 else { throw EndToEndError.fixtureBuildFailed("ditto: \(copied.combinedOutput)") }
    }
}

private actor FixtureBuild {
    private var built: URL?

    func folder(script: URL) async throws -> URL {
        if let built { return built }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EndToEndFixtures-\(UUID().uuidString)", isDirectory: true)
        let output = root.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if sharedFixturesExitPath == nil {
            sharedFixturesExitPath = root.path
            atexit {
                if let path = sharedFixturesExitPath { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        let result = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path, output.path]
        )
        guard result.exitCode == 0 else {
            throw EndToEndError.fixtureBuildFailed("exit \(result.exitCode): \(result.combinedOutput)")
        }
        built = output
        return output
    }
}
