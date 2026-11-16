import Foundation

/// Installs a `.pkg` by handing it to Installer.app. macOS shows the prompt and takes the password.
/// SettleIn never sees it. SettleIn watches for the app bundle and the package receipt, so
/// `PackageInstallState.installing` is inferred, not read from Installer.app.
public struct PackageInstaller: Sendable {
    /// How long the installer waits for the install to finish before it reports `timedOut`.
    public static let defaultTimeout: Duration = .seconds(600)
    public static let pollInterval: Duration = .seconds(1)

    private enum Tool {
        static let open = URL(fileURLWithPath: "/usr/bin/open")
        static let pkgutil = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        static let installerApp = "/System/Library/CoreServices/Installer.app"
    }

    private let verifier: any PackageSignatureChecking
    private let runner: any CommandRunner
    private let locator: any BundleLocator
    private let monitor: any InstallerProcessMonitor
    private let clock: any PollingClock
    private let timeout: Duration

    public init(
        verifier: any PackageSignatureChecking = SignatureVerifier(),
        runner: any CommandRunner = ProcessCommandRunner(),
        locator: any BundleLocator = WorkspaceBundleLocator(),
        monitor: any InstallerProcessMonitor = RunningApplicationInstallerMonitor(),
        clock: any PollingClock = SystemPollingClock(),
        timeout: Duration = PackageInstaller.defaultTimeout
    ) {
        self.verifier = verifier
        self.runner = runner
        self.locator = locator
        self.monitor = monitor
        self.clock = clock
        self.timeout = timeout
    }

    /// Verifies the package, opens it in Installer.app, and reports progress until a final state.
    /// Cancelling the task that reads the stream stops the polling. It does not quit Installer.app,
    /// because an install in progress has to finish or fail on its own.
    public func install(package: URL, app: CatalogApp) -> AsyncStream<PackageInstallState> {
        AsyncStream { continuation in
            let task = Task {
                let final = await run(package: package, app: app) { continuation.yield($0) }
                continuation.yield(final)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends the non-final states to `report` and returns the final one.
    private func run(
        package: URL,
        app: CatalogApp,
        report: @Sendable (PackageInstallState) -> Void
    ) async -> PackageInstallState {
        guard case .pkg(let identifier) = app.install else { return .failed(.notAPackageEntry) }
        if case .invalid(let failure) = await verifier.verifyPackage(at: package, expecting: app.teamID) {
            return .failed(.signature(failure))
        }
        if locator.applicationURL(forBundleID: app.bundleID) != nil { return .failed(.alreadyInstalled) }
        guard await openInstaller(with: package) else { return .failed(.installerDidNotOpen) }

        report(.waitingForUser)
        return await poll(bundleID: app.bundleID, identifier: identifier, report: report)
    }

    private func openInstaller(with package: URL) async -> Bool {
        let result = try? await runner.run(executable: Tool.open, arguments: ["-a", Tool.installerApp, package.path])
        return result?.exitCode == 0
    }

    private func poll(
        bundleID: BundleID,
        identifier: PackageIdentifier,
        report: @Sendable (PackageInstallState) -> Void
    ) async -> PackageInstallState {
        var elapsed = Duration.zero
        var announcedInstalling = false
        while !Task.isCancelled {
            if locator.applicationURL(forBundleID: bundleID) != nil {
                if await receiptExists(for: identifier) { return .installed }
                if !announcedInstalling {
                    announcedInstalling = true
                    report(.installing)
                }
            } else if elapsed > .zero && !monitor.isInstallerRunning() {
                // The first poll skips this check so a slow Installer.app start is not read as a quit.
                return .cancelled
            }
            if elapsed >= timeout { return .failed(.timedOut) }
            do {
                try await clock.sleep(for: Self.pollInterval)
            } catch {
                return .cancelled
            }
            elapsed += Self.pollInterval
        }
        return .cancelled
    }

    /// `pkgutil --pkg-info` exits with 0 when macOS has a receipt for the identifier.
    private func receiptExists(for identifier: PackageIdentifier) async -> Bool {
        let result = try? await runner.run(executable: Tool.pkgutil, arguments: ["--pkg-info", identifier.rawValue])
        return result?.exitCode == 0
    }
}
