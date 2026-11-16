import Foundation
@testable import SettleInCore

/// Plays back one result for `open` and a script for `pkgutil`. It records every call and runs nothing.
actor PackageFakeRunner: CommandRunner {
    struct Call: Equatable {
        let tool: String
        let arguments: [String]
    }

    private let openExitCode: Int32
    private let throwsOnOpen: Bool
    private let receiptAfterChecks: Int?
    private(set) var calls: [Call] = []
    private var receiptChecks = 0

    /// `receiptAfterChecks` is the number of `pkgutil` calls that fail before one succeeds. Nil means never.
    init(openExitCode: Int32 = 0, throwsOnOpen: Bool = false, receiptAfterChecks: Int? = nil) {
        self.openExitCode = openExitCode
        self.throwsOnOpen = throwsOnOpen
        self.receiptAfterChecks = receiptAfterChecks
    }

    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        let tool = executable.lastPathComponent
        calls.append(Call(tool: tool, arguments: arguments))
        switch tool {
        case "open":
            if throwsOnOpen { throw CommandRunnerError.executableNotAbsolute("fake") }
            return CommandResult(exitCode: openExitCode)
        case "pkgutil":
            receiptChecks += 1
            let exists = receiptAfterChecks.map { receiptChecks > $0 } ?? false
            return CommandResult(exitCode: exists ? 0 : 1)
        default:
            return CommandResult(exitCode: 99, stderr: "unexpected tool \(tool)")
        }
    }

    var toolNames: [String] { calls.map(\.tool) }
}

struct PackageFakeVerifier: PackageSignatureChecking {
    let result: SignatureResult

    func verifyPackage(at package: URL, expecting expected: TeamID) async -> SignatureResult { result }
}

/// Reports the app as installed once `appearsAfterChecks` lookups have returned nil. Nil means never.
final class PackageFakeLocator: BundleLocator, @unchecked Sendable {
    private let lock = NSLock()
    private let appearsAfterChecks: Int?
    private var checks = 0

    init(appearsAfterChecks: Int?) { self.appearsAfterChecks = appearsAfterChecks }

    var checkCount: Int { lock.withLock { checks } }

    func applicationURL(forBundleID bundleID: BundleID) -> URL? {
        lock.withLock {
            checks += 1
            guard let appearsAfterChecks, checks > appearsAfterChecks else { return nil }
            return URL(fileURLWithPath: "/fixture/path/Some App.app")
        }
    }
}

/// Reports Installer.app as running for the first `runningChecks` calls, then as quit.
final class PackageFakeMonitor: InstallerProcessMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private let runningChecks: Int
    private var checks = 0

    init(runningChecks: Int) { self.runningChecks = runningChecks }

    func isInstallerRunning() -> Bool {
        lock.withLock {
            checks += 1
            return checks <= runningChecks
        }
    }
}

/// Returns at once and adds up the time it was asked to wait. With `holds` set, it waits until the
/// task is cancelled instead, so a test can stop a run in the middle.
final class PackageFakeClock: PollingClock, @unchecked Sendable {
    private let lock = NSLock()
    private let holds: Bool
    private var slept = Duration.zero
    private var sleeps = 0
    private var interruptions = 0

    init(holds: Bool = false) { self.holds = holds }

    var totalSlept: Duration { lock.withLock { slept } }
    var sleepCount: Int { lock.withLock { sleeps } }
    var interruptedSleeps: Int { lock.withLock { interruptions } }

    func sleep(for duration: Duration) async throws {
        lock.withLock { sleeps += 1 }
        if holds {
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                lock.withLock { interruptions += 1 }
                throw error
            }
        }
        await Task.yield()
        lock.withLock { slept += duration }
    }
}

func packageCatalogApp(install: InstallMethod? = nil) -> CatalogApp {
    guard
        let team = TeamID("EQHXZ8M8AV"),
        let bundle = BundleID("com.example.Some"),
        let identifier = PackageIdentifier("com.example.Some.pkg"),
        let host = AllowedHost("example.com"),
        let download = URL(string: "https://example.com/Some.pkg")
    else { fatalError("bad fixture literal") }
    return CatalogApp(
        id: "some", name: "Some", category: "Tools", homepage: download,
        version: .latest, install: install ?? .pkg(identifier: identifier),
        allowedHosts: [host], teamID: team, bundleID: bundle, uninstallPaths: [],
        source: .universal(CatalogDownload(url: download, sha256: nil))
    )
}

let packageFixtureURL = URL(fileURLWithPath: "/fixture/path/Some.pkg")

func collectStates(_ stream: AsyncStream<PackageInstallState>) async -> [PackageInstallState] {
    var states: [PackageInstallState] = []
    for await state in stream { states.append(state) }
    return states
}
