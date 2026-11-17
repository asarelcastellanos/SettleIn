import Foundation
import Testing
@testable import SettleInCore

/// A scratch tree for one uninstall test. It holds a fake home, a fake applications folder, a fake Trash,
/// and an `outside` folder with a canary file. Every test works inside `root` and never reads or changes the
/// real `/Applications` or the real home folder. `root` is not resolved, so on a Mac it sits under the
/// `/var` symbolic link, which the guard must resolve.
struct UninstallSandbox {
    let root: URL
    let home: URL
    let applications: URL
    let trashFolder: URL
    let outside: URL

    var roots: AllowedRoots { AllowedRoots(home: home, applications: applications) }
    var support: URL { home.appendingPathComponent("Library/Application Support", isDirectory: true) }
    var config: URL { home.appendingPathComponent(".config", isDirectory: true) }
    var canary: URL { outside.appendingPathComponent("canary.txt") }

    static func make() throws -> UninstallSandbox {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettleIn-uninstall-test-\(UUID().uuidString)", isDirectory: true)
        let sandbox = UninstallSandbox(
            root: base,
            home: base.appendingPathComponent("home", isDirectory: true),
            applications: base.appendingPathComponent("Applications", isDirectory: true),
            trashFolder: base.appendingPathComponent("Trash", isDirectory: true),
            outside: base.appendingPathComponent("outside", isDirectory: true)
        )
        let folders = [sandbox.support, sandbox.config, sandbox.applications, sandbox.trashFolder, sandbox.outside,
                       sandbox.home.appendingPathComponent("Documents", isDirectory: true)]
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "canary".write(to: sandbox.canary, atomically: true, encoding: .utf8)
        try "canary".write(
            to: sandbox.home.appendingPathComponent("Documents/canary.txt"), atomically: true, encoding: .utf8
        )
        return sandbox
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    var canariesIntact: Bool {
        let files = [canary, home.appendingPathComponent("Documents/canary.txt")]
        return files.allSatisfy { (try? String(contentsOf: $0, encoding: .utf8)) == "canary" }
    }

    func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    func makeSymlink(at link: URL, to target: URL) throws {
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }

    func makeFolder(_ url: URL, file: String = "data.txt") throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try "data".write(to: url.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    /// Writes a bundle with only an `Info.plist`, which is all the uninstaller reads.
    @discardableResult
    func makeApp(named name: String, bundleID: String) throws -> URL {
        try makeBundle(at: applications.appendingPathComponent(name, isDirectory: true), bundleID: bundleID)
    }

    @discardableResult
    func makeBundle(at app: URL, bundleID: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true
        )
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "Test"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
}

enum UninstallTestApp {
    static let bundleID = "com.example.SettleInUninstallTest"
    static let name = "Doomed.app"

    static func catalogApp(
        bundleID: String = UninstallTestApp.bundleID,
        install: InstallMethod? = nil,
        paths: [String] = []
    ) throws -> CatalogApp {
        guard
            let team = TeamID("EQHXZ8M8AV"),
            let bundle = BundleID(bundleID),
            let appName = AppBundleName(name),
            let host = AllowedHost("example.com"),
            let download = URL(string: "https://example.com/Doomed.zip")
        else { fatalError("bad fixture literal") }
        return CatalogApp(
            id: "doomed", name: "Doomed", category: "Tools", homepage: download,
            version: .latest, install: install ?? .zip(appName: appName),
            allowedHosts: [host], teamID: team, bundleID: bundle,
            uninstallPaths: try paths.map { try UninstallPath($0) },
            source: .universal(CatalogDownload(url: download, sha256: nil))
        )
    }
}

/// Stands in for the Trash. It moves an item into the sandbox, or fails on demand.
final class FakeTrash: @unchecked Sendable {
    private let folder: URL
    private let fails: Bool
    private let lock = NSLock()
    private var calls: [String] = []
    /// Runs inside a failing call, before it throws. A test uses it to change the tree mid-removal.
    private let beforeFailing: @Sendable (URL) -> Void

    init(folder: URL, fails: Bool = false, beforeFailing: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.folder = folder
        self.fails = fails
        self.beforeFailing = beforeFailing
    }

    var trashedPaths: [String] { lock.withLock { calls } }

    func trash(_ path: ApprovedPath) throws {
        lock.withLock { calls.append(path.url.path) }
        if fails {
            beforeFailing(path.url)
            throw CocoaError(.fileWriteNoPermission)
        }
        let name = "\(UUID().uuidString)-\(path.url.lastPathComponent)"
        try FileManager.default.moveItem(at: path.url, to: folder.appendingPathComponent(name))
    }
}

extension Uninstaller {
    static func testing(
        _ sandbox: UninstallSandbox,
        trash: FakeTrash,
        runningApps: any RunningAppProviding = FakeRunningApps(running: false),
        quitAnswer: Bool = true,
        quitCounter: CallCounter = CallCounter()
    ) -> Uninstaller {
        Uninstaller(
            roots: sandbox.roots,
            runningApps: runningApps,
            trash: { try trash.trash($0) },
            confirmQuit: { _ in quitCounter.increment(); return quitAnswer }
        )
    }
}

extension UninstallReport {
    var outcomes: [UninstallOutcome] { items.map(\.outcome) }
}
