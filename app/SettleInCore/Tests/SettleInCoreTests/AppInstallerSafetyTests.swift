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

    @Test func attachTimeoutWaitsForTheChildToEndBeforeItDetaches() async throws {
        let sandbox = try InstallSandbox.make()
        let image = sandbox.sources.appendingPathComponent("never-opens.dmg")
        let order = OrderLog()
        let slow = "4242.7"
        let runner = InterceptingRunner { tool, arguments in
            guard tool.lastPathComponent == "hdiutil" else { return nil }
            if arguments.first == "attach" {
                order.add("attach started")
                do {
                    return try await ProcessCommandRunner().run(
                        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: [slow]
                    )
                } catch {
                    order.add("attach ended")
                    throw error
                }
            }
            if arguments.first == "detach", !arguments.contains("-force") {
                let probe = try await ProcessCommandRunner().run(
                    executable: URL(fileURLWithPath: "/usr/bin/pgrep"), arguments: ["-f", "sleep \(slow)"]
                )
                order.add(probe.exitCode == 0 ? "detach while the child runs" : "detach after the child ended")
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
}
