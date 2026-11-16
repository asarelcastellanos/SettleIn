import Foundation
import Testing
@testable import SettleInCore

/// A scratch folder for one test. `cleanUp` removes it and checks that `hdiutil info` lists no image from it.
struct InstallSandbox {
    let root: URL
    let destination: URL
    let temporaryRoot: URL
    let sources: URL

    static func make() throws -> InstallSandbox {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettleIn-installer-test-\(UUID().uuidString)", isDirectory: true)
        let sandbox = InstallSandbox(
            root: base,
            destination: base.appendingPathComponent("Applications", isDirectory: true),
            temporaryRoot: base.appendingPathComponent("tmp", isDirectory: true),
            sources: base.appendingPathComponent("sources", isDirectory: true)
        )
        for folder in [sandbox.destination, sandbox.temporaryRoot, sandbox.sources] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return sandbox
    }

    /// Fails the test when an image from this sandbox is still attached, then removes the sandbox.
    func cleanUp() async {
        let attached = await attachedImagePaths()
        #expect(attached.filter { $0.contains(root.lastPathComponent) }.isEmpty, "an image is still attached")
        // A test that made the destination read-only needs it writable again before removal.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        try? FileManager.default.removeItem(at: root)
    }

    func entries(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func attachedImagePaths() async -> [String] {
        let result = try? await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["info", "-plist"]
        )
        guard
            let result,
            let plist = try? PropertyListSerialization.propertyList(from: Data(result.stdout.utf8), format: nil),
            let images = (plist as? [String: Any])?["images"] as? [[String: Any]]
        else { return [] }
        return images.compactMap { $0["image-path"] as? String }
    }
}

enum TestApp {
    static let bundleID = "com.example.SettleInTestApp"
    static let name = "Test App.app"

    static var target: InstallTarget {
        guard let appName = AppBundleName(name), let bundle = BundleID(bundleID) else {
            fatalError("bad test constants")
        }
        return InstallTarget(appName: appName, bundleID: bundle, teamID: teamID("ABCDE12345"))
    }

    /// Builds a tiny app that never runs, signs it ad hoc, and writes `marker` so a test can tell versions apart.
    @discardableResult
    static func build(in folder: URL, name: String = TestApp.name, bundleID: String = TestApp.bundleID,
                      marker: String = "one") async throws -> URL {
        let app = folder.appendingPathComponent(name, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("tiny")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleExecutable": "tiny",
            "CFBundleName": "Tiny", "CFBundlePackageType": "APPL", "Marker": marker
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let signed = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", app.path]
        )
        try #require(signed.exitCode == 0, "codesign failed: \(signed.stderr)")
        return app
    }

    static func marker(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["Marker"] as? String
    }

    static func makeDMG(from folder: URL, at output: URL) async throws {
        let result = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["create", "-quiet", "-srcfolder", folder.path, "-volname", "SettleInTest",
                        "-format", "UDZO", "-ov", output.path]
        )
        try #require(result.exitCode == 0, "hdiutil create failed: \(result.stderr)")
    }

    /// Packs `source` into a zip. With `keepParent`, the zip root holds `source` itself, as a vendor's zip of an
    /// app does. Without it, the zip root holds what `source` contains.
    static func makeZip(from source: URL, at output: URL, keepParent: Bool = true) async throws {
        let flags = keepParent ? ["-c", "-k", "--keepParent"] : ["-c", "-k"]
        let result = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: flags + [source.path, output.path]
        )
        try #require(result.exitCode == 0, "ditto failed: \(result.stderr)")
    }
}

/// Answers with a fixed result and records the paths it was asked to verify.
actor StubSignatureChecker: AppSignatureChecking {
    private let result: SignatureResult
    private(set) var verifiedPaths: [String] = []

    init(_ result: SignatureResult) { self.result = result }

    func verifyApp(at app: URL, expecting expected: TeamID) async -> SignatureResult {
        verifiedPaths.append(app.path)
        return result
    }
}

extension AppSignatureChecking where Self == StubSignatureChecker {
    static func passing(_ team: TeamID) -> StubSignatureChecker { StubSignatureChecker(.valid(team)) }
}

final class FakeRunningApps: RunningAppProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool
    private let quitSucceeds: Bool
    private var timeouts: [Duration] = []

    init(running: Bool, quitSucceeds: Bool = true) {
        self.running = running
        self.quitSucceeds = quitSucceeds
    }

    func isRunning(bundleID: BundleID) -> Bool {
        lock.withLock { running }
    }

    func terminate(bundleID: BundleID, timeout: Duration) async -> Bool {
        lock.withLock {
            timeouts.append(timeout)
            if quitSucceeds { running = false }
            return quitSucceeds
        }
    }

    var terminateTimeouts: [Duration] { lock.withLock { timeouts } }
}

struct FakeFreeSpace: FreeSpaceProviding {
    let bytes: Int64
    func availableBytes(onVolumeOf url: URL) throws -> Int64 { bytes }
}

/// Counts how often a confirmation closure ran.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var timesCalled: Int { lock.withLock { value } }
}

/// Forwards to another runner, except that `intercept` may answer a call itself.
struct InterceptingRunner: CommandRunner {
    let inner: any CommandRunner = ProcessCommandRunner()
    let calls = CallLog()
    let intercept: @Sendable (URL, [String]) async throws -> CommandResult?

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        calls.record(executable.lastPathComponent, arguments)
        if let answer = try await intercept(executable, arguments) { return answer }
        return try await inner.run(executable: executable, arguments: arguments)
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(tool: String, arguments: [String])] = []
    func record(_ tool: String, _ arguments: [String]) { lock.withLock { entries.append((tool, arguments)) } }
    func count(of tool: String) -> Int { lock.withLock { entries.filter { $0.tool == tool }.count } }
}

extension AppInstaller {
    /// An installer wired to the sandbox, with confirmations that count their calls and answer as told.
    static func testing(
        _ sandbox: InstallSandbox,
        runner: any CommandRunner = ProcessCommandRunner(),
        checker: any AppSignatureChecking,
        runningApps: any RunningAppProviding = FakeRunningApps(running: false),
        freeSpace: any FreeSpaceProviding = FakeFreeSpace(bytes: .max),
        attachTimeout: Duration = .seconds(60),
        replaceAnswer: Bool = true,
        replaceCounter: CallCounter = CallCounter(),
        quitAnswer: Bool = true,
        quitCounter: CallCounter = CallCounter()
    ) -> AppInstaller {
        AppInstaller(
            destination: sandbox.destination,
            runner: runner,
            signatureChecker: checker,
            runningApps: runningApps,
            freeSpace: freeSpace,
            attachTimeout: attachTimeout,
            temporaryRoot: sandbox.temporaryRoot,
            confirmReplace: { _ in replaceCounter.increment(); return replaceAnswer },
            confirmQuit: { _ in quitCounter.increment(); return quitAnswer }
        )
    }
}

/// Runs `body` and returns the `InstallError` it throws. Records an issue when it succeeds or throws another error.
func installFailure(_ body: () async throws -> some Any) async -> InstallError? {
    do {
        _ = try await body()
        Issue.record("the install succeeded")
    } catch let error as InstallError {
        return error
    } catch {
        Issue.record("unexpected error \(error)")
    }
    return nil
}

extension InstallSandbox {
    func makeDMG(marker: String = "one") async throws -> URL {
        let folder = sources.appendingPathComponent("dmg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await TestApp.build(in: folder, marker: marker)
        let image = sources.appendingPathComponent("app-\(UUID().uuidString).dmg")
        try await TestApp.makeDMG(from: folder, at: image)
        return image
    }

    func makeZip(extra: (URL) throws -> Void = { _ in }) async throws -> URL {
        let folder = sources.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = try await TestApp.build(in: folder)
        try extra(folder)
        let archive = sources.appendingPathComponent("app-\(UUID().uuidString).zip")
        let hasExtra = try FileManager.default.contentsOfDirectory(atPath: folder.path).count > 1
        if hasExtra {
            try await TestApp.makeZip(from: folder, at: archive, keepParent: false)
        } else {
            try await TestApp.makeZip(from: app, at: archive)
        }
        return archive
    }
}
