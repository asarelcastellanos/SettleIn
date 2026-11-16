import Foundation
import Testing
@testable import SettleInCore

/// Archive safety and mounting. These tests run real `hdiutil` and `ditto` in a temp folder. They extend
/// `AppInstallerTests`, so the suite's serial setting and the `--filter AppInstallerTests` run cover them.
extension AppInstallerTests {
    // MARK: Zip safety

    @Test func zipWithASymlinkOutsideFailsAndCopiesNothing() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip { folder in
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent("etc-link"), withDestinationURL: URL(fileURLWithPath: "/etc")
            )
        }
        let checker = StubSignatureChecker(.valid(team))
        let installer = AppInstaller.testing(sandbox, checker: checker)

        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }

        guard case .unsafeArchiveItem(let path) = error else {
            Issue.record("expected unsafeArchiveItem, got \(String(describing: error))")
            await sandbox.cleanUp()
            return
        }
        #expect(path.contains("etc-link"))
        #expect(error?.errorDescription?.contains("outside") == true)
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        #expect(await checker.verifiedPaths.isEmpty)
        await sandbox.cleanUp()
    }

    @Test func zipWithARelativeLinkThatClimbsOutFails() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip { folder in
            try FileManager.default.createSymbolicLink(
                atPath: folder.appendingPathComponent("up").path, withDestinationPath: "../../.."
            )
        }
        let installer = AppInstaller.testing(sandbox, checker: .passing(team))
        let error = await installFailure { try await installer.install(archive: archive, kind: .zip, app: target) }
        guard case .unsafeArchiveItem = error else {
            Issue.record("expected unsafeArchiveItem, got \(String(describing: error))")
            await sandbox.cleanUp()
            return
        }
        #expect(sandbox.entries(in: sandbox.destination).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func zipWithALinkInsideTheFolderIsAccepted() async throws {
        let sandbox = try InstallSandbox.make()
        let archive = try await sandbox.makeZip { folder in
            try FileManager.default.createSymbolicLink(
                atPath: folder.appendingPathComponent("inside").path, withDestinationPath: TestApp.name
            )
        }
        let installer = AppInstaller.testing(sandbox, checker: .passing(team))
        try await installer.install(archive: archive, kind: .zip, app: target)
        #expect(sandbox.entries(in: sandbox.destination) == [TestApp.name])
        await sandbox.cleanUp()
    }

    // MARK: Mount

    @Test func attachThatNeverFinishesTimesOutAndDetaches() async throws {
        let sandbox = try InstallSandbox.make()
        let image = sandbox.sources.appendingPathComponent("never.dmg")
        let runner = InterceptingRunner { _, arguments in
            if arguments.first == "attach" {
                try await Task.sleep(for: .seconds(60))
                return CommandResult(exitCode: 0)
            }
            return CommandResult(exitCode: 1, stderr: "not mounted")
        }
        let installer = AppInstaller.testing(
            sandbox, runner: runner, checker: .passing(team), attachTimeout: .milliseconds(200)
        )

        let error = await installFailure { try await installer.install(archive: image, kind: .dmg, app: target) }

        #expect(error == .mountTimedOut)
        #expect(error?.errorDescription?.contains("60 seconds") == true)
        // The detach ran once, then again with -force.
        #expect(runner.calls.count(of: "hdiutil") == 3)
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func corruptImageFailsWithAReadableError() async throws {
        let sandbox = try InstallSandbox.make()
        let image = sandbox.sources.appendingPathComponent("corrupt.dmg")
        try Data("this is not a disk image".utf8).write(to: image)
        let installer = AppInstaller.testing(sandbox, checker: .passing(team))

        let error = await installFailure { try await installer.install(archive: image, kind: .dmg, app: target) }

        guard case .mountFailed = error else {
            Issue.record("expected mountFailed, got \(String(describing: error))")
            await sandbox.cleanUp()
            return
        }
        #expect(sandbox.entries(in: sandbox.temporaryRoot).isEmpty)
        await sandbox.cleanUp()
    }

    @Test func attachPlistYieldsOnlyTheRequestedMountPoint() {
        let requested = URL(fileURLWithPath: "/tmp/work/mnt")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>system-entities</key><array>
        <dict><key>dev-entry</key><string>/dev/disk9</string></dict>
        <dict><key>mount-point</key><string>/Volumes/Elsewhere</string></dict>
        <dict><key>mount-point</key><string>/tmp/work/mnt</string></dict>
        </array></dict></plist>
        """
        #expect(DiskImageMounter.mountPoint(inAttachPlist: plist, expecting: requested)?.path == "/tmp/work/mnt")
        #expect(DiskImageMounter.mountPoint(inAttachPlist: "not a plist", expecting: requested) == nil)
        let other = plist.replacingOccurrences(of: "/tmp/work/mnt", with: "/tmp/work/other")
        #expect(DiskImageMounter.mountPoint(inAttachPlist: other, expecting: requested) == nil)
    }
}
