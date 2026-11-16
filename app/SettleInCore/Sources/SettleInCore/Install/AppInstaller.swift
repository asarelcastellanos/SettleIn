import Foundation

/// Installs a verified `.app` from a downloaded dmg or zip.
///
/// The installer unpacks the archive into a private directory, copies the app to a staging folder there,
/// checks the signature of that copy, and only then copies the copy into the destination folder. It never
/// checks the signature of the mounted image alone, and it never asks for a password.
public struct AppInstaller: Sendable {
    let destination: URL
    let runner: any CommandRunner
    let signatureChecker: any AppSignatureChecking
    let runningApps: any RunningAppProviding
    let freeSpace: any FreeSpaceProviding
    let attachTimeout: Duration
    let quitTimeout: Duration
    let temporaryRoot: URL
    let confirmReplace: @Sendable (InstallTarget) async -> Bool
    let confirmQuit: @Sendable (InstallTarget) async -> Bool

    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    /// - Parameters:
    ///   - destination: The folder that receives the app.
    ///   - confirmReplace: Asked when an app with the same bundle ID is already at the destination.
    ///   - confirmQuit: Asked when the app is running. After a yes, the installer asks the app to quit.
    ///   - temporaryRoot: Where the private working directory goes. Tests pass a folder they can inspect.
    public init(
        destination: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        runner: any CommandRunner = ProcessCommandRunner(),
        signatureChecker: any AppSignatureChecking = SignatureVerifier(),
        runningApps: any RunningAppProviding = WorkspaceRunningApps(),
        freeSpace: any FreeSpaceProviding = VolumeFreeSpace(),
        attachTimeout: Duration = .seconds(60),
        quitTimeout: Duration = .seconds(10),
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        confirmReplace: @escaping @Sendable (InstallTarget) async -> Bool,
        confirmQuit: @escaping @Sendable (InstallTarget) async -> Bool
    ) {
        self.destination = destination
        self.runner = runner
        self.signatureChecker = signatureChecker
        self.runningApps = runningApps
        self.freeSpace = freeSpace
        self.attachTimeout = attachTimeout
        self.quitTimeout = quitTimeout
        self.temporaryRoot = temporaryRoot
        self.confirmReplace = confirmReplace
        self.confirmQuit = confirmQuit
    }

    /// Installs the app and returns its path in the destination folder. The private directory and the mounted
    /// image are gone when this returns or throws.
    @discardableResult
    public func install(archive: URL, kind: InstallKind, app: InstallTarget) async throws -> URL {
        try requireWritableDestination()
        let installed = destination.appendingPathComponent(app.appName.rawValue, isDirectory: true)
        let replacing = try existingApp(at: installed, matches: app.bundleID)

        let work = try makeWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: work) }

        let staged: URL
        switch kind {
        case .dmg:
            let mounter = DiskImageMounter(runner: runner, attachTimeout: attachTimeout)
            staged = try await mounter.withMount(of: archive, in: work) { mount in
                try await stageVerifiedCopy(of: app, from: mount, in: work)
            }
        case .zip:
            let extract = work.appendingPathComponent("extract", isDirectory: true)
            try await unpackZip(archive, into: extract)
            staged = try await stageVerifiedCopy(of: app, from: extract, in: work)
        }

        if replacing {
            guard await confirmReplace(app) else { throw InstallError.replaceDeclined }
        }
        try await quitIfRunning(app)
        try await place(staged, at: installed, replacing: replacing)
        return installed
    }

    // MARK: Checks before any work

    private func requireWritableDestination() throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue, FileManager.default.isWritableFile(atPath: destination.path) else {
            throw InstallError.destinationNotWritable(path: destination.path)
        }
    }

    /// Returns true when an app with the catalog bundle ID is at `path`. Throws when anything else is there.
    /// A symbolic link, a plain file, and a bundle without a readable identifier all count as another app.
    private func existingApp(at path: URL, matches bundleID: BundleID) throws -> Bool {
        let manager = FileManager.default
        guard let type = try? manager.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType else {
            return false
        }
        let plist = path.appendingPathComponent("Contents/Info.plist")
        guard
            type == .typeDirectory,
            let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            info["CFBundleIdentifier"] as? String == bundleID.rawValue
        else {
            throw InstallError.differentAppAtDestination(path: path.path)
        }
        return true
    }

    private func makeWorkingDirectory() throws -> URL {
        let directory = temporaryRoot.appendingPathComponent("SettleIn-install-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw InstallError.workingDirectoryFailed
        }
        return directory
    }

    // MARK: Unpack and stage

    private func unpackZip(_ zip: URL, into extract: URL) async throws {
        _ = try await execute(Self.ditto, ["-x", "-k", zip.path, extract.path]) {
            InstallError.extractFailed(detail: $0)
        }
        try UnpackedItems.verifyContained(in: extract)
    }

    /// Finds the app in `folder`, checks the free space, copies the app into the private directory, and
    /// verifies that copy. Returns the copy, which is the only thing that goes on to the destination.
    private func stageVerifiedCopy(of target: InstallTarget, from folder: URL, in work: URL) async throws -> URL {
        let source = folder.appendingPathComponent(target.appName.rawValue, isDirectory: true)
        let type = try? FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
        guard type == .typeDirectory else { throw InstallError.appNotFound(name: target.appName.rawValue) }

        let needed = 2 * UnpackedItems.allocatedSize(of: source)
        let available = try freeSpace.availableBytes(onVolumeOf: destination)
        guard available >= needed else { throw InstallError.notEnoughSpace(needed: needed, available: available) }

        let stagingFolder = work.appendingPathComponent("staged", isDirectory: true)
        let staged = stagingFolder.appendingPathComponent(target.appName.rawValue, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: false)
        } catch {
            throw InstallError.workingDirectoryFailed
        }
        try await copy(source, to: staged)

        switch await signatureChecker.verifyApp(at: staged, expecting: target.teamID) {
        case .valid: return staged
        case .invalid(let failure): throw InstallError.signatureInvalid(failure)
        }
    }

    // MARK: Placement

    /// Asks the app to quit when it is running. The installer never forces it. A refusal, a failed quit, and
    /// an app that is still running after the wait all end the install.
    private func quitIfRunning(_ target: InstallTarget) async throws {
        guard runningApps.isRunning(bundleID: target.bundleID) else { return }
        guard await confirmQuit(target) else { throw InstallError.appStillRunning }
        guard await runningApps.terminate(bundleID: target.bundleID, timeout: quitTimeout) else {
            throw InstallError.appStillRunning
        }
    }

    /// Copies `staged` to a hidden name in the destination folder, then moves it into place. A reader never
    /// sees a half-copied app at the final path, and the hidden copy is removed on every exit path.
    private func place(_ staged: URL, at installed: URL, replacing: Bool) async throws {
        let manager = FileManager.default
        let pending = destination.appendingPathComponent(".SettleIn-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: pending) }
        try await copy(staged, to: pending)
        do {
            if replacing {
                _ = try manager.replaceItemAt(installed, withItemAt: pending)
            } else {
                try manager.moveItem(at: pending, to: installed)
            }
        } catch {
            throw InstallError.copyFailed(detail: "The app could not be moved into \(destination.path).")
        }
    }

    private func copy(_ source: URL, to target: URL) async throws {
        _ = try await execute(Self.ditto, [source.path, target.path]) { InstallError.copyFailed(detail: $0) }
    }

    /// Runs one tool through the injected runner. A nonzero exit or a tool that does not start becomes the
    /// error that `failure` builds from a short description.
    private func execute(
        _ tool: URL,
        _ arguments: [String],
        failure: (String) -> InstallError
    ) async throws -> CommandResult {
        let result: CommandResult
        do {
            result = try await runner.run(executable: tool, arguments: arguments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw failure("The \(tool.lastPathComponent) tool did not start.")
        }
        guard result.exitCode == 0 else { throw failure(ToolOutput.summary(of: result)) }
        return result
    }
}
