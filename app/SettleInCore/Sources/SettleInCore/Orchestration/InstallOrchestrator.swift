import Foundation

/// One change of an app's state. The orchestrator publishes these in order.
public struct StateChange: Equatable, Sendable {
    public let appID: String
    public let state: InstallState
}

/// Why the orchestrator did not start an operation.
public enum OperationRefusal: Equatable, Sendable {
    /// Another operation on the same app is still running. That operation is not affected.
    case busy
    /// The app's state does not allow the request, such as an install of an installed app.
    case notAllowedInCurrentState
}

public enum OperationOutcome: Equatable, Sendable {
    /// The operation ran to the end. The value is the app's state afterwards.
    case completed(InstallState)
    case refused(OperationRefusal)
}

/// Runs one operation per app at a time and keeps each app's state and log.
///
/// An install downloads the file first. The download passes the SHA-256 check before anything else sees
/// the file. After that, a dmg or zip goes to `AppInstaller`, which verifies the signature of its staged
/// copy before it copies anything into the destination. A pkg goes to `PackageInstaller`, which verifies
/// the package signature before it opens Installer.app. Neither installer reports the signature result
/// early, so the orchestrator records `verifying` for the whole call and moves to `installing` only after
/// the installer reports that verification passed. The row text for a dmg or zip says "Checking and
/// installing" during `verifying`, because the installer checks the signature and copies the app inside its
/// call. The row text for a pkg says "Waiting for Installer" during `installing`, because SettleIn polls for
/// the app while Installer.app works. The reducer has no event from `downloading` to `installing`, so no
/// install reaches `installing` without `verifying`.
///
/// A question that the user answers with no, such as replacing an app or quitting it, ends the operation
/// with the `declined` event, and no failure shows. An uninstall returns to `installed`. An install returns to
/// `idle`, and then the orchestrator asks the locator, so an app that is already installed shows as installed.
public actor InstallOrchestrator {
    private let downloader: any AppDownloading
    private let appInstaller: any AppInstalling
    private let packageInstaller: any PackageInstalling
    private let uninstaller: any AppUninstalling
    private let locator: any BundleLocator
    private let architecture: CPUArchitecture
    private let now: @Sendable () -> Date
    private let homeDirectory: String

    private var states: [String: InstallState] = [:]
    private var logs: [String: OperationLog] = [:]
    private var runs: [String: Run] = [:]

    /// One running operation. The token tells a finished run apart from a newer run on the same app.
    private struct Run {
        let token: UUID
        let task: Task<Void, Never>
    }

    /// Every state change in order. One reader should consume it.
    public nonisolated let stateChanges: AsyncStream<StateChange>
    private let changeSink: AsyncStream<StateChange>.Continuation

    public init(
        downloader: any AppDownloading = Downloader(),
        appInstaller: any AppInstalling,
        packageInstaller: any PackageInstalling = PackageInstaller(),
        uninstaller: any AppUninstalling,
        locator: any BundleLocator = WorkspaceBundleLocator(),
        architecture: CPUArchitecture = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.downloader = downloader
        self.appInstaller = appInstaller
        self.packageInstaller = packageInstaller
        self.uninstaller = uninstaller
        self.locator = locator
        self.architecture = architecture
        self.now = now
        self.homeDirectory = homeDirectory
        (stateChanges, changeSink) = AsyncStream.makeStream(of: StateChange.self)
    }

    public func state(of appID: String) -> InstallState {
        states[appID] ?? .idle
    }

    /// The log of the latest operation on the app.
    public func log(for appID: String) -> OperationLog {
        logs[appID] ?? OperationLog(homeDirectory: homeDirectory)
    }

    /// Marks each idle app as installed when LaunchServices finds its bundle ID.
    public func detectInstalled(in apps: [CatalogApp]) {
        for app in apps where locator.applicationURL(forBundleID: app.bundleID) != nil {
            apply(.appFound, to: app.id)
        }
    }

    // MARK: Install

    /// Installs the app and returns when the install ends. A request on an app that is busy returns a
    /// refusal at once and leaves the running operation alone.
    @discardableResult
    public func install(_ app: CatalogApp) async -> OperationOutcome {
        if let refusal = refusal(for: app.id, event: .installRequested) { return .refused(refusal) }
        startLog(for: app.id, "install requested for \(app.name)")
        apply(.installRequested, to: app.id)
        let task = Task { await runInstall(app) }
        return await finish(task, for: app.id)
    }

    /// Cancels a download. Once the download ends, the install cannot be cancelled, because the
    /// installers could leave a half-copied app behind.
    public func cancel(appID: String) {
        guard case .downloading = state(of: appID) else { return }
        record(appID, "cancel requested")
        runs[appID]?.task.cancel()
    }

    private func runInstall(_ app: CatalogApp) async {
        let download = app.source.download(for: architecture)
        record(app.id, "download \(download.url.absoluteString)")
        do {
            let integrity = try await downloader.download(
                source: download,
                allowedHosts: app.allowedHosts,
                progress: { [self] progress in
                    Task { await apply(.downloadProgressed(fraction: progress.fraction), to: app.id) }
                },
                body: { file in try await installDownloaded(file, of: app) }
            )
            record(app.id, Self.describe(integrity))
            if state(of: app.id).isBusy { fail(app.id, .interrupted) }
        } catch {
            conclude(app, error: error)
        }
    }

    private func installDownloaded(_ file: URL, of app: CatalogApp) async throws {
        try Task.checkCancellation()
        apply(.downloadFinished, to: app.id)
        record(app.id, "downloaded to \(file.path)")
        switch app.install {
        case .dmg(let appName):
            try await installArchive(file, kind: .dmg, appName: appName, of: app)
        case .zip(let appName):
            try await installArchive(file, kind: .zip, appName: appName, of: app)
        case .pkg:
            await installPackage(file, of: app)
        }
    }

    private func installArchive(
        _ file: URL,
        kind: InstallKind,
        appName: AppBundleName,
        of app: CatalogApp
    ) async throws {
        record(app.id, "AppInstaller: verify the staged copy of \(appName.rawValue), then install it")
        let target = InstallTarget(appName: appName, bundleID: app.bundleID, teamID: app.teamID)
        let notes = InstallNotes()
        let installed: URL
        do {
            installed = try await appInstaller.install(
                archive: file, kind: kind, app: target, report: { notes.add($0) }
            )
        } catch {
            recordNotes(notes, for: app.id)
            throw error
        }
        recordNotes(notes, for: app.id)
        record(app.id, "installed at \(installed.path)")
        apply(.verified, to: app.id)
        apply(.installFinished, to: app.id)
    }

    private func installPackage(_ file: URL, of app: CatalogApp) async {
        record(app.id, "PackageInstaller: verify the package, then open Installer.app")
        for await packageState in packageInstaller.install(package: file, app: app) {
            switch packageState {
            case .waitingForUser:
                record(app.id, "PackageInstaller: package verified, waiting for Installer.app")
                apply(.verified, to: app.id)
            case .installing:
                apply(.verified, to: app.id)
            case .installed:
                record(app.id, "PackageInstaller: app and receipt found")
                apply(.verified, to: app.id)
                apply(.installFinished, to: app.id)
            case .cancelled:
                record(app.id, "PackageInstaller: Installer.app quit before the app appeared")
                apply(.cancelled, to: app.id)
            case .failed(let failure):
                fail(app.id, .package(failure))
            }
        }
    }

    // MARK: Uninstall

    /// Removes the app and returns when the removal ends.
    @discardableResult
    public func uninstall(_ app: CatalogApp) async -> OperationOutcome {
        if let refusal = refusal(for: app.id, event: .uninstallRequested) { return .refused(refusal) }
        startLog(for: app.id, "uninstall requested for \(app.name)")
        apply(.uninstallRequested, to: app.id)
        let task = Task { await runUninstall(app) }
        return await finish(task, for: app.id)
    }

    private func runUninstall(_ app: CatalogApp) async {
        do {
            let report = try await uninstaller.uninstall(app: app)
            var leftAlone = 0
            for item in report.items {
                record(app.id, Self.describe(item))
                if case .refused = item.outcome { leftAlone += 1 }
            }
            if leftAlone > 0 {
                fail(app.id, .uninstallIncomplete(leftAlone: leftAlone))
            } else if let remaining = installedCopy(of: app) {
                record(app.id, "the app is still at \(remaining.path)")
                fail(app.id, .stillPresentAfterUninstall)
            } else {
                apply(.uninstallFinished, to: app.id)
            }
        } catch {
            conclude(app, error: error)
        }
    }

    /// The copy of the app that LaunchServices still reports after an uninstall. A path that is gone, and a
    /// path inside a Trash folder, do not count.
    private func installedCopy(of app: CatalogApp) -> URL? {
        guard let url = locator.applicationURL(forBundleID: app.bundleID) else { return nil }
        let inTrash = url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
        return !inTrash && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Shared steps

    /// The check and the state change that follows it run without a suspension point in between, so two
    /// requests on one app cannot both pass.
    private func refusal(for appID: String, event: InstallEvent) -> OperationRefusal? {
        let current = state(of: appID)
        if current.isBusy { return .busy }
        return current.reduce(event) == current ? .notAllowedInCurrentState : nil
    }

    /// Waits for the task. A cancel followed at once by a new request lets the new run register before this
    /// call resumes, so the run is cleared only when its token is still the registered one.
    private func finish(_ task: Task<Void, Never>, for appID: String) async -> OperationOutcome {
        let token = UUID()
        runs[appID] = Run(token: token, task: task)
        await task.value
        if runs[appID]?.token == token { runs[appID] = nil }
        return .completed(state(of: appID))
    }

    private func recordNotes(_ notes: InstallNotes, for appID: String) {
        for note in notes.drain() { record(appID, "AppInstaller: \(note)") }
    }

    private func conclude(_ app: CatalogApp, error: any Error) {
        let appID = app.id
        if error is CancellationError {
            record(appID, "cancelled")
            apply(.cancelled, to: appID)
            return
        }
        if isDecline(error) {
            record(appID, "declined by the user")
            apply(.declined, to: appID)
            // A declined install returns to idle, so ask the locator whether the app is already installed.
            if state(of: appID) == .idle, let found = installedCopy(of: app) {
                record(appID, "the app is installed at \(found.path)")
                apply(.appFound, to: appID)
            }
            return
        }
        if InstallFailure.from(error) == .unexpected {
            record(appID, "unexpected error of type \(type(of: error))")
        }
        fail(appID, InstallFailure.from(error))
    }

    private func fail(_ appID: String, _ failure: InstallFailure) {
        record(appID, "failed: \(failure.userMessage)")
        if let exit = failure.toolExit {
            record(appID, "tool \(exit.tool) exited with code \(exit.exitCode)")
        }
        apply(.failed(failure), to: appID)
    }

    @discardableResult
    private func apply(_ event: InstallEvent, to appID: String) -> InstallState {
        let old = state(of: appID)
        let new = old.reduce(event)
        guard new != old else { return old }
        states[appID] = new
        if old.name != new.name { record(appID, "state: \(old.name) -> \(new.name)") }
        if Self.isVisible(from: old, to: new) { changeSink.yield(StateChange(appID: appID, state: new)) }
        return new
    }

    /// Progress reports arrive many times a second. Readers see a new value only when the whole
    /// percent changes.
    private static func isVisible(from old: InstallState, to new: InstallState) -> Bool {
        guard case .downloading(let before) = old, case .downloading(let after) = new else { return true }
        return before.map { Int($0 * 100) } != after.map { Int($0 * 100) }
    }

    private func startLog(for appID: String, _ text: String) {
        logs[appID] = OperationLog(homeDirectory: homeDirectory)
        record(appID, text)
    }

    private func record(_ appID: String, _ text: String) {
        logs[appID, default: OperationLog(homeDirectory: homeDirectory)].append(text, at: now())
    }

    private static func describe(_ integrity: DownloadIntegrity) -> String {
        switch integrity {
        case .verified(let digest): "download matches the pinned SHA-256 \(digest.rawValue)"
        case .unpinned: "the catalog pins no SHA-256 for this download, so only the signature check applies"
        }
    }

    private static func describe(_ item: UninstallItem) -> String {
        switch item.outcome {
        case .trashed: "moved to the Trash: \(item.path)"
        case .deleted: "deleted after the Trash failed: \(item.path)"
        case .skipped: "nothing found at \(item.path)"
        case .refused(let reason): "left alone: \(item.path) (\(reason))"
        }
    }
}

/// Collects the notes that `AppInstaller` reports during one call. The installer calls it from its own tasks,
/// and the orchestrator reads it after the call returns.
private final class InstallNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [String] = []

    func add(_ note: String) { lock.withLock { notes.append(note) } }

    func drain() -> [String] { lock.withLock { defer { notes = [] }; return notes } }
}

/// True when the user answered no to a question that the installer or the uninstaller asked.
private func isDecline(_ error: any Error) -> Bool {
    switch error {
    case InstallError.replaceDeclined, InstallError.quitDeclined, UninstallError.quitDeclined: true
    default: false
    }
}
