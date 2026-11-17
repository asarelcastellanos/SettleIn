import Foundation
import Testing
@testable import SettleInCore

/// Runs real `hdiutil` and `ditto` against tiny ad hoc signed apps in a temp folder. Nothing here touches
/// `/Applications`, launches an app, or reads an installed app.
@Suite(.serialized)
struct AppInstallerTests {
    let target = TestApp.target
    var team: TeamID { target.teamID }

    // MARK: Success

    @Test func dmgInstallsTheVerifiedStagedCopy() async throws {
        let sandbox = try InstallSandbox.make()
        let checker = StubSignatureChecker(.valid(team))
        let image = try await sandbox.makeDMG()
        let installer = AppInstaller.testing(sandbox, checker: checker)

        let installed = try await installer.install(archive: image, kind: .dmg, app: target)

        #expect(installed.lastPathComponent == TestApp.name)
        #expect(sandbox.entries(in: sandbox.destination) == [TestApp.name])
        #expect(TestApp.marker(of: installed) == "one")
        let verified = await checker.verifiedPaths
        #expect(verified.count == 1)
        #expect(verified.allSatisfy { $0.contains("SettleIn-install-") && !$0.contains("/mnt/") })
        #expect(await checker.expectedTeamIDs == [teamID("ABCDE12345")])
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func zipInstallsTheVerifiedStagedCopy() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip()
        let installer = AppInstaller.testing(sandbox, checker: .passing(team))

        let installed = try await installer.install(archive: archive, kind: .zip, app: target)

        #expect(TestApp.marker(of: installed) == "one")
        #expect(sandbox.entries(in: sandbox.destination) == [TestApp.name])
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func workingDirectoryIsPrivateWhileTheInstallRuns() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip()
        let observed = CallLog()
        let runner = InterceptingRunner { _, arguments in
            if let path = arguments.last, path.contains("SettleIn-install-") {
                let work = URL(fileURLWithPath: path).deletingLastPathComponent()
                let mode = (try? FileManager.default.attributesOfItem(atPath: work.path)[.posixPermissions]) as? Int
                observed.record(String(mode ?? -1, radix: 8), [])
            }
            return nil
        }
        let installer = AppInstaller.testing(sandbox, runner: runner, checker: .passing(team))
        try await installer.install(archive: archive, kind: .zip, app: target)
        #expect(observed.count(of: "700") > 0)
        await sandbox.cleanUp()
    }

    // MARK: Failures that leave nothing behind

    @Test func failedSignatureCheckLeavesNoImageAndNoCopy() async throws {
        let sandbox = try InstallSandbox.make()
        let image = try await sandbox.makeDMG()
        let checker = StubSignatureChecker(.invalid(.teamIDMismatch(expected: "ABCDE12345", actual: "ZZZZZ99999")))
        let installer = AppInstaller.testing(sandbox, checker: checker)

        let error = await installFailure { try await installer.install(archive: image, kind: .dmg, app: target) }

        #expect(error == .signatureInvalid(.teamIDMismatch(expected: "ABCDE12345", actual: "ZZZZZ99999")))
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func failedCopyLeavesNoImageAndNoCopy() async throws {
        let sandbox = try InstallSandbox.make()
        let image = try await sandbox.makeDMG()
        let destinationPath = sandbox.destination.path
        let runner = InterceptingRunner { tool, arguments in
            guard tool.lastPathComponent == "ditto", let last = arguments.last, last.hasPrefix(destinationPath) else {
                return nil
            }
            return CommandResult(exitCode: 1, stderr: "disk full")
        }
        let installer = AppInstaller.testing(sandbox, runner: runner, checker: .passing(team))

        let error = await installFailure { try await installer.install(archive: image, kind: .dmg, app: target) }

        #expect(error == .copyFailed(detail: "disk full"))
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func notEnoughSpaceFailsBeforeAnyCopy() async throws {
        let sandbox = try InstallSandbox.make()
        let image = try await sandbox.makeDMG()
        let runner = InterceptingRunner { _, _ in nil }
        let installer = AppInstaller.testing(
            sandbox, runner: runner, checker: .passing(team), freeSpace: FakeFreeSpace(bytes: 1)
        )

        let error = await installFailure { try await installer.install(archive: image, kind: .dmg, app: target) }

        guard case .notEnoughSpace(let needed, let available) = error else {
            Issue.record("expected notEnoughSpace, got \(String(describing: error))")
            await sandbox.cleanUp()
            return
        }
        #expect(available == 1)
        #expect(needed > 1)
        #expect(runner.calls.count(of: "ditto") == 0)
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func missingAppInTheArchiveFails() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip()
        let other = try #require(AppBundleName("Other.app"))
        let wrong = InstallTarget(appName: other, bundleID: target.bundleID, teamID: team)
        let installer = AppInstaller.testing(sandbox, checker: .passing(team))

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: wrong) }

        #expect(error == .appNotFound(name: "Other.app"))
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func unwritableDestinationFailsWithAReadableError() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sandbox.destination.path)
        let installer = AppInstaller.testing(sandbox, checker: .passing(team))

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }

        #expect(error == .destinationNotWritable(path: sandbox.destination.path))
        #expect(error?.errorDescription?.contains("password") == true)
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    // MARK: Already installed

    @Test func differentAppWithTheSameNameStaysUntouched() async throws {
        let sandbox = try InstallSandbox.make()
        let existing = try await TestApp.build(
            in: sandbox.destination, bundleID: "com.example.Other", marker: "other"
        )
        let archive = try await sandbox.makeZip()
        let replaceCounter = CallCounter()
        let installer = AppInstaller.testing(sandbox, checker: .passing(team), replaceCounter: replaceCounter)

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }

        #expect(error == .differentAppAtDestination(path: existing.path))
        #expect(TestApp.marker(of: existing) == "other")
        #expect(replaceCounter.timesCalled == 0)
        #expect(sandbox.entries(in: sandbox.destination) == [TestApp.name])
        await sandbox.cleanUp()
    }

    @Test func sameBundleIDDeclinedLeavesTheOldAppInPlace() async throws {
        let sandbox = try InstallSandbox.make()
        let existing = try await TestApp.build(in: sandbox.destination, marker: "old")
        let image = try await sandbox.makeDMG(marker: "new")
        let replaceCounter = CallCounter()
        let installer = AppInstaller.testing(
            sandbox, checker: .passing(team), replaceAnswer: false, replaceCounter: replaceCounter
        )

        let error = await installFailure { try await installer.install(archive: image, kind: .dmg, app: target) }

        #expect(error == .replaceDeclined)
        #expect(replaceCounter.timesCalled == 1)
        #expect(TestApp.marker(of: existing) == "old")
        #expect(sandbox.entries(in: sandbox.destination) == [TestApp.name])
        await sandbox.cleanUp()
    }

    @Test func sameBundleIDConfirmedReplacesTheOldApp() async throws {
        let sandbox = try InstallSandbox.make()
        let existing = try await TestApp.build(in: sandbox.destination, marker: "old")
        let image = try await sandbox.makeDMG(marker: "new")
        let replaceCounter = CallCounter()
        let installer = AppInstaller.testing(sandbox, checker: .passing(team), replaceCounter: replaceCounter)

        try await installer.install(archive: image, kind: .dmg, app: target)

        #expect(replaceCounter.timesCalled == 1)
        #expect(TestApp.marker(of: existing) == "new")
        #expect(sandbox.entries(in: sandbox.destination) == [TestApp.name])
        await sandbox.cleanUp()
    }

    // MARK: Running app

    @Test func refusingToQuitFailsWithQuitDeclined() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip()
        let running = FakeRunningApps(running: true)
        let quitCounter = CallCounter()
        let installer = AppInstaller.testing(
            sandbox, checker: .passing(team), runningApps: running, quitAnswer: false, quitCounter: quitCounter
        )

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }

        #expect(error == .quitDeclined)
        #expect(quitCounter.timesCalled == 1)
        #expect(running.terminateTimeouts.isEmpty)
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func appThatStaysRunningFailsAfterTheTenSecondWait() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip()
        let running = FakeRunningApps(running: true, quitSucceeds: false)
        let installer = AppInstaller.testing(sandbox, checker: .passing(team), runningApps: running)

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }

        #expect(error == .appStillRunning)
        #expect(running.terminateTimeouts == [.seconds(10)])
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func confirmedQuitThenInstallSucceeds() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip()
        let running = FakeRunningApps(running: true)
        let installer = AppInstaller.testing(sandbox, checker: .passing(team), runningApps: running)

        try await installer.install(archive: archive, kind: .zip, app: target)

        #expect(running.terminateTimeouts == [.seconds(10)])
        #expect(sandbox.entries(in: sandbox.destination) == [TestApp.name])
        await sandbox.cleanUp()
    }
}
