import Foundation
import Testing
@testable import SettleInCore

/// The installer's checks after the signature, and its cleanup reports. These extend `AppInstallerTests`, so
/// the suite's serial setting and the `--filter AppInstallerTests` run cover them.
extension AppInstallerTests {
    // MARK: Bundle ID of the staged copy

    @Test func zipWhoseBundleIDIsNotTheCatalogsIsRefusedEvenWithAValidSignature() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip(bundleID: "com.example.Impostor")
        let checker = StubSignatureChecker(.valid(team))
        let installer = AppInstaller.testing(sandbox, checker: checker)

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }

        #expect(error == .bundleIDMismatch(expected: TestApp.bundleID))
        #expect(await checker.verifiedPaths.count == 1, "the signature check passed before the bundle ID check")
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func dmgWhoseBundleIDIsNotTheCatalogsIsRefusedEvenWithAValidSignature() async throws {
        let sandbox = try InstallSandbox.make()
        let image = try await sandbox.makeDMG(bundleID: "com.example.Impostor")
        let installer = AppInstaller.testing(sandbox, checker: .passing(team))

        let error = await installFailure { try await installer.install(archive: image, kind: .dmg, app: target) }

        #expect(error == .bundleIDMismatch(expected: TestApp.bundleID))
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    // MARK: Destination read again

    @Test func appSwappedForAnotherDuringTheReplaceQuestionIsLeftAlone() async throws {
        let sandbox = try InstallSandbox.make()
        let existing = try await TestApp.build(in: sandbox.destination, marker: "old")
        let archive = try await sandbox.makeZip()
        let destination = sandbox.destination
        let installer = AppInstaller(
            destination: destination,
            signatureChecker: StubSignatureChecker.passing(team),
            runningApps: FakeRunningApps(running: false),
            freeSpace: FakeFreeSpace(bytes: .max),
            temporaryRoot: sandbox.temporaryRoot,
            confirmReplace: { _ in
                try? FileManager.default.removeItem(at: existing)
                _ = try? await TestApp.build(in: destination, bundleID: "com.example.Other", marker: "swapped")
                return true
            },
            confirmQuit: { _ in true }
        )

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }

        #expect(error == .differentAppAtDestination(path: existing.path))
        #expect(TestApp.marker(of: existing) == "swapped")
        #expect(sandbox.entries(in: sandbox.destination) == [TestApp.name])
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func appThatAppearsDuringTheCopyIsNeverReplacedWithoutAQuestion() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip()
        let destinationPath = sandbox.destination.path
        let destination = sandbox.destination
        let replaceCounter = CallCounter()
        let runner = InterceptingRunner { tool, arguments in
            if tool.lastPathComponent == "ditto", let last = arguments.last, last.hasPrefix(destinationPath) {
                _ = try await TestApp.build(in: destination, marker: "appeared")
            }
            return nil
        }
        let installer = AppInstaller.testing(
            sandbox, runner: runner, checker: .passing(team), replaceCounter: replaceCounter
        )

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }

        let installed = destination.appendingPathComponent(TestApp.name)
        #expect(error == .differentAppAtDestination(path: installed.path))
        #expect(replaceCounter.timesCalled == 0)
        #expect(TestApp.marker(of: installed) == "appeared")
        #expect(sandbox.entries(in: sandbox.destination) == [TestApp.name])
        await sandbox.cleanUp()
    }

    @Test func aSymlinkAtTheDestinationIsNotTheInstalledApp() async throws {
        let sandbox = try InstallSandbox.make()
        let real = try await TestApp.build(in: sandbox.sources, marker: "real")
        let link = sandbox.destination.appendingPathComponent(TestApp.name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let archive = try await sandbox.makeZip()
        let replaceCounter = CallCounter()
        let installer = AppInstaller.testing(sandbox, checker: .passing(team), replaceCounter: replaceCounter)

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }

        #expect(error == .differentAppAtDestination(path: link.path))
        #expect(replaceCounter.timesCalled == 0)
        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(TestApp.marker(of: real) == "real")
        await sandbox.cleanUp()
    }

    // MARK: Cleanup reports

    @Test func aFailedDetachIsReportedAndTheInstallStillSucceeds() async throws {
        let sandbox = try InstallSandbox.make()
        let image = try await sandbox.makeDMG()
        // The forced detach runs for real, so no image stays mounted, and then reports a failure.
        let runner = InterceptingRunner { tool, arguments in
            guard tool.lastPathComponent == "hdiutil", arguments.first == "detach" else { return nil }
            if arguments.contains("-force") {
                _ = try await ProcessCommandRunner().run(executable: tool, arguments: arguments)
            }
            return CommandResult(exitCode: 1, stderr: "Resource busy")
        }
        let installer = AppInstaller.testing(sandbox, runner: runner, checker: .passing(team))
        let notes = OrderLog()

        let installed = try await installer.install(
            archive: image, kind: .dmg, app: target, report: { notes.add($0) }
        )

        #expect(TestApp.marker(of: installed) == "one")
        #expect(notes.entries.count == 1)
        #expect(notes.entries.first?.contains("was not detached") == true)
        #expect(notes.entries.first?.contains("exited with code 1") == true)
        #expect(notes.entries.first?.contains("Resource busy") == false, "tool output stays out of the notes")
        await sandbox.cleanUp()
    }

    @Test func aWorkingFolderThatCannotBeRemovedIsReportedAndTheInstallStillSucceeds() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip()
        let destinationPath = sandbox.destination.path
        let temporaryRoot = sandbox.temporaryRoot
        // After the last copy, the parent of the working folder becomes read-only, so the removal fails.
        let runner = InterceptingRunner { tool, arguments in
            if tool.lastPathComponent == "ditto", let last = arguments.last, last.hasPrefix(destinationPath) {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temporaryRoot.path)
            }
            return nil
        }
        let installer = AppInstaller.testing(sandbox, runner: runner, checker: .passing(team))
        let notes = OrderLog()

        let installed = try await installer.install(
            archive: archive, kind: .zip, app: target, report: { notes.add($0) }
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporaryRoot.path)

        #expect(TestApp.marker(of: installed) == "one")
        #expect(notes.entries.count == 1)
        #expect(notes.entries.first?.contains("could not remove its working folder") == true)
        await sandbox.cleanUp()
    }

    // MARK: Attach timeout

    private static func perlSleeper(_ marker: String) -> (URL, [String]) {
        (URL(fileURLWithPath: "/usr/bin/perl"), ["-e", "sleep $ARGV[0];", "600", marker])
    }

    private static func isRunning(matching text: String) async throws -> Bool {
        let probe = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", text]
        )
        return probe.exitCode == 0
    }

    private static func killChildren(matching text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-9", "-f", text]
        try? process.run()
        process.waitUntilExit()
    }

    @Test func attachTimeoutWaitsForTheChildToEndBeforeItDetaches() async throws {
        let sandbox = try InstallSandbox.make()
        let image = sandbox.sources.appendingPathComponent("never-opens.dmg")
        let order = OrderLog()
        let marker = "SettleInAttachTest-\(UUID().uuidString)"
        defer { Self.killChildren(matching: marker) }
        let runner = InterceptingRunner { tool, arguments in
            guard tool.lastPathComponent == "hdiutil" else { return nil }
            if arguments.first == "attach" {
                order.add("attach started")
                let (perl, perlArguments) = Self.perlSleeper(marker)
                do {
                    return try await ProcessCommandRunner().run(executable: perl, arguments: perlArguments)
                } catch {
                    order.add("attach ended")
                    throw error
                }
            }
            if arguments.first == "detach", !arguments.contains("-force") {
                let running = try await Self.isRunning(matching: marker)
                order.add(running ? "detach while the child runs" : "detach after the child ended")
            }
            return nil
        }
        let installer = AppInstaller.testing(
            sandbox, runner: runner, checker: .passing(team), attachTimeout: .seconds(1)
        )

        let error = await installFailure { try await installer.install(archive: image, kind: .dmg, app: target) }

        #expect(error == .mountTimedOut)
        #expect(order.entries == ["attach started", "attach ended", "detach after the child ended"])
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func attachTimeoutDoesNotWaitForAGrandchildThatHoldsThePipes() async throws {
        let sandbox = try InstallSandbox.make()
        let image = sandbox.sources.appendingPathComponent("never-opens.dmg")
        let marker = "SettleInAttachTest-\(UUID().uuidString)"
        let ready = sandbox.root.appendingPathComponent("ready")
        defer { Self.killChildren(matching: marker) }
        let script = #"trap "" TERM; /usr/bin/perl -e 'sleep $ARGV[0];' 600 "$1" & wait"#
        let runner = InterceptingRunner { tool, arguments in
            guard tool.lastPathComponent == "hdiutil", arguments.first == "attach" else { return nil }
            return try await ProcessCommandRunner(terminationGrace: .milliseconds(300)).run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "sh", marker, ready.path]
            )
        }
        let installer = AppInstaller.testing(
            sandbox, runner: runner, checker: .passing(team), attachTimeout: .seconds(1)
        )
        let start = ContinuousClock.now

        let error = await installFailure { try await installer.install(archive: image, kind: .dmg, app: target) }

        #expect(error == .mountTimedOut)
        #expect(ContinuousClock.now - start < .seconds(10), "the attach waited for the grandchild")
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    // MARK: Cancel

    /// The mount points of images that the sandbox owns.
    private static func mountPoints(of sandbox: InstallSandbox) async throws -> [String] {
        let info = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["info", "-plist"]
        )
        guard
            let plist = try? PropertyListSerialization.propertyList(from: Data(info.stdout.utf8), format: nil),
            let images = (plist as? [String: Any])?["images"] as? [[String: Any]]
        else { return [] }
        return images
            .filter { ($0["image-path"] as? String)?.contains(sandbox.root.lastPathComponent) == true }
            .flatMap { ($0["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String } }
    }

    @Test func cancellingAfterTheImageIsAttachedStillDetachesIt() async throws {
        let sandbox = try InstallSandbox.make()
        let image = try await sandbox.makeDMG()
        let order = OrderLog()
        // The copy out of the image waits for the cancel, so the image is attached when the cancel arrives.
        let runner = InterceptingRunner { tool, _ in
            guard tool.lastPathComponent == "ditto" else { return nil }
            order.add("copying")
            try await Task.sleep(for: .seconds(60))
            return nil
        }
        let installer = AppInstaller.testing(sandbox, runner: runner, checker: .passing(team))
        let task = Task { try await installer.install(archive: image, kind: .dmg, app: target) }
        #expect(await eventually { order.entries.contains("copying") })

        task.cancel()
        let outcome = await task.result

        guard case .failure(let error) = outcome else {
            Issue.record("the cancelled install returned a result")
            await sandbox.cleanUp()
            return
        }
        #expect(error is CancellationError)
        let leftover = try await Self.mountPoints(of: sandbox)
        #expect(leftover.isEmpty, "the image is still mounted at \(leftover)")
        for mountPoint in leftover {
            _ = try await ProcessCommandRunner().run(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", "-force", mountPoint]
            )
        }
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }
}
