import Foundation
import Testing
@testable import SettleInCore

/// Opens once. Every waiter resumes after `open`.
actor OrchestratorGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Polls until `condition` holds, for up to five seconds.
func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Stands in for the downloader. It writes a small file into a private folder under `root`, runs `body`,
/// and removes the folder on every exit path, as the real downloader does. It never touches the network.
final class FakeDownloader: AppDownloading, @unchecked Sendable {
    enum Behavior {
        case succeed
        case fail(any Error)
        /// Fails the first call and succeeds on every later call.
        case failOnce(any Error)
        /// Reports `progress`, then waits until the task is cancelled.
        case hold(progress: Double?)
        /// Waits for the gate, then succeeds. The wait ignores cancellation.
        case gated(OrchestratorGate)
    }

    private let root: URL
    private let behavior: Behavior
    private let lock = NSLock()
    private var recordedSources: [CatalogDownload] = []
    private var recordedHosts: [[AllowedHost]] = []

    init(root: URL, behavior: Behavior = .succeed) {
        self.root = root
        self.behavior = behavior
    }

    var sources: [CatalogDownload] { lock.withLock { recordedSources } }
    var hosts: [[AllowedHost]] { lock.withLock { recordedHosts } }

    func download(
        source: CatalogDownload,
        allowedHosts: [AllowedHost],
        progress: @escaping @Sendable (DownloadProgress) -> Void,
        body: (URL) async throws -> Void
    ) async throws -> DownloadIntegrity {
        let callNumber = lock.withLock {
            recordedSources.append(source)
            recordedHosts.append(allowedHosts)
            return recordedSources.count
        }
        let directory = root.appendingPathComponent("FakeDownload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.bin")
        try Data("payload".utf8).write(to: file)

        switch behavior {
        case .succeed:
            break
        case .fail(let error):
            throw error
        case .failOnce(let error):
            if callNumber == 1 { throw error }
        case .hold(let fraction):
            if let fraction {
                progress(DownloadProgress(bytesReceived: Int64(fraction * 100), totalBytes: 100))
            }
            try await Task.sleep(for: .seconds(60))
        case .gated(let gate):
            await gate.wait()
        }
        try await body(file)
        return source.sha256.map { .verified($0) } ?? .unpinned
    }
}

final class FakeAppInstaller: AppInstalling, @unchecked Sendable {
    struct Call: Equatable {
        let kind: InstallKind
        let target: InstallTarget
        let archiveExisted: Bool
    }

    private let result: Result<URL, any Error>
    private let notes: [String]
    private let lock = NSLock()
    private var recordedCalls: [Call] = []

    /// `notes` are sent to the `report` closure of every call, before the result.
    init(
        result: Result<URL, any Error> = .success(URL(fileURLWithPath: "/Applications/Fixture.app")),
        notes: [String] = []
    ) {
        self.result = result
        self.notes = notes
    }

    var calls: [Call] { lock.withLock { recordedCalls } }

    func install(archive: URL, kind: InstallKind, app: InstallTarget, report: InstallReport?) async throws -> URL {
        notes.forEach { report?($0) }
        return try await install(archive: archive, kind: kind, app: app)
    }

    func install(archive: URL, kind: InstallKind, app: InstallTarget) async throws -> URL {
        let existed = FileManager.default.fileExists(atPath: archive.path)
        lock.withLock { recordedCalls.append(Call(kind: kind, target: app, archiveExisted: existed)) }
        return try result.get()
    }
}

final class FakePackageInstaller: PackageInstalling, @unchecked Sendable {
    private let states: [PackageInstallState]
    private let holds: Bool
    private let lock = NSLock()
    private var recordedPackageExisted: [Bool] = []
    private var terminations = 0

    /// With `holds`, the stream stays open after `states`, as the real poll does while Installer.app is open.
    init(states: [PackageInstallState] = [.waitingForUser, .installing, .installed], holds: Bool = false) {
        self.states = states
        self.holds = holds
    }

    var packageExistedAtCall: [Bool] { lock.withLock { recordedPackageExisted } }

    /// True once the reader of a stream stopped, which is what stops the real polling.
    var wasStopped: Bool { lock.withLock { terminations > 0 } }

    func install(package: URL, app: CatalogApp) -> AsyncStream<PackageInstallState> {
        let existed = FileManager.default.fileExists(atPath: package.path)
        lock.withLock { recordedPackageExisted.append(existed) }
        return AsyncStream { continuation in
            states.forEach { continuation.yield($0) }
            if !holds { continuation.finish() }
            continuation.onTermination = { [self] _ in lock.withLock { terminations += 1 } }
        }
    }
}

final class FakeUninstaller: AppUninstalling, @unchecked Sendable {
    private let result: Result<UninstallReport, any Error>
    private let lock = NSLock()
    private var recordedApps: [String] = []

    init(result: Result<UninstallReport, any Error> = .success(UninstallReport(items: []))) {
        self.result = result
    }

    var appIDs: [String] { lock.withLock { recordedApps } }

    func uninstall(app: CatalogApp) async throws -> UninstallReport {
        lock.withLock { recordedApps.append(app.id) }
        return try result.get()
    }
}

/// Reports a URL for each bundle ID in `found`. The default URL sits in a temp folder that nothing creates, so
/// an uninstall test sees the app as gone and never reads the real `/Applications`. A test that needs the app
/// to exist on disk passes a URL of its own.
struct FakeBundleLocator: BundleLocator {
    let found: Set<String>
    var url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FakeLocator-\(UUID().uuidString)/Fixture.app", isDirectory: true)

    func applicationURL(forBundleID bundleID: BundleID) -> URL? {
        found.contains(bundleID.rawValue) ? url : nil
    }
}

/// Collects the orchestrator's state changes in order.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [StateChange] = []
    private var reader: Task<Void, Never>?

    init(_ orchestrator: InstallOrchestrator) {
        let stream = orchestrator.stateChanges
        reader = Task { [self] in
            for await change in stream { lock.withLock { changes.append(change) } }
        }
    }

    deinit { reader?.cancel() }

    func states(of appID: String) -> [InstallState] {
        lock.withLock { changes.filter { $0.appID == appID }.map(\.state) }
    }

    func names(of appID: String) -> [String] {
        states(of: appID).map(\.name)
    }

    /// Waits until the recorder has seen the given case names for the app.
    func sawNames(_ expected: [String], of appID: String) async -> Bool {
        await eventually { names(of: appID) == expected }
    }
}

enum OrchestratorFixture {
    enum Kind { case dmg, zip, pkg }

    static let sha256 = "a" + String(repeating: "b", count: 63)

    static func download(_ path: String, pinned: Bool = true) -> CatalogDownload {
        guard let url = URL(string: "https://downloads.example.com/" + path) else { fatalError("bad fixture literal") }
        return CatalogDownload(url: url, sha256: pinned ? SHA256Digest(sha256) : nil)
    }

    static func app(
        _ kind: Kind,
        source: DownloadSource? = nil,
        id: String? = nil,
        bundleID: String = "com.example.OrchestratorFixture"
    ) -> CatalogApp {
        guard
            let team = TeamID("EQHXZ8M8AV"),
            let bundle = BundleID(bundleID),
            let appName = AppBundleName("Fixture.app"),
            let identifier = PackageIdentifier("com.example.OrchestratorFixture"),
            let host = AllowedHost("downloads.example.com"),
            let homepage = URL(string: "https://example.com"),
            let uninstallPath = try? UninstallPath("/Applications/Fixture.app")
        else { fatalError("bad fixture literal") }
        let install: InstallMethod
        switch kind {
        case .dmg: install = .dmg(appName: appName)
        case .zip: install = .zip(appName: appName)
        case .pkg: install = .pkg(identifier: identifier)
        }
        return CatalogApp(
            id: id ?? "fixture-\(kind)", name: "Fixture \(kind)", category: "Tools", homepage: homepage,
            version: .pinned("1.0"), install: install, allowedHosts: [host], teamID: team, bundleID: bundle,
            uninstallPaths: [uninstallPath], source: source ?? .universal(download("Fixture-1.0.\(kind)"))
        )
    }
}

/// An orchestrator wired to fakes, with the pieces a test inspects.
struct OrchestratorHarness {
    let orchestrator: InstallOrchestrator
    let downloader: FakeDownloader
    let appInstaller: FakeAppInstaller
    let packageInstaller: FakePackageInstaller
    let uninstaller: FakeUninstaller
    let recorder: StateRecorder

    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    init(
        root: URL,
        home: String = "/Users/tester",
        downloader behavior: FakeDownloader.Behavior = .succeed,
        appInstaller: FakeAppInstaller = FakeAppInstaller(),
        packageInstaller: FakePackageInstaller = FakePackageInstaller(),
        uninstaller: FakeUninstaller = FakeUninstaller(),
        installedBundleIDs: Set<String> = [],
        locatedAt locatedURL: URL? = nil,
        architecture: CPUArchitecture = .arm64
    ) {
        downloader = FakeDownloader(root: root, behavior: behavior)
        self.appInstaller = appInstaller
        self.packageInstaller = packageInstaller
        self.uninstaller = uninstaller
        orchestrator = InstallOrchestrator(
            downloader: downloader,
            appInstaller: appInstaller,
            packageInstaller: packageInstaller,
            uninstaller: uninstaller,
            locator: locatedURL.map { FakeBundleLocator(found: installedBundleIDs, url: $0) }
                ?? FakeBundleLocator(found: installedBundleIDs),
            architecture: architecture,
            now: { Self.fixedDate },
            homeDirectory: home
        )
        recorder = StateRecorder(orchestrator)
    }
}
