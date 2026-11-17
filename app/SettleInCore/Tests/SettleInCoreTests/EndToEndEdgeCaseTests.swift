import Foundation
import Testing
@testable import SettleInCore

/// The edge cases from the manual test plan that a test can run without a person. The user cancelling
/// Installer.app is in `EndToEndPackageTests`.
extension IntegrationTests {
    private static let passing = StubSignatureChecker(.valid(EndToEndWorld.expectedTeam))

    // MARK: Network drop

    @Test func networkDropMidTransferInstallsNothing() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.dmg, delivery: .dropsHalfway)
            let checker = StubSignatureChecker(.valid(EndToEndWorld.expectedTeam))
            let installer = AppInstaller.testing(world.install, checker: checker)
            let (orchestrator, _) = world.makeOrchestrator(installer: installer)

            let outcome = await orchestrator.install(app)

            let lost = URLError(.networkConnectionLost).errorCode
            #expect(failure(of: outcome) == .download(.transferFailed(code: lost)))
            #expect(await checker.verifiedPaths.isEmpty)
            #expect(world.installedApps.isEmpty)
            #expect(world.leftovers.isEmpty)
        }
    }

    // MARK: Disk full

    @Test func notEnoughFreeSpaceStopsBeforeAnyCopy() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.dmg)
            let checker = StubSignatureChecker(.valid(EndToEndWorld.expectedTeam))
            let installer = AppInstaller.testing(world.install, checker: checker, freeSpace: FakeFreeSpace(bytes: 1024))
            let (orchestrator, _) = world.makeOrchestrator(installer: installer)

            let outcome = await orchestrator.install(app)

            let result = try #require(failure(of: outcome))
            guard case .install(.notEnoughSpace(let needed, let available)) = result else {
                Issue.record("expected notEnoughSpace, got \(result)")
                return
            }
            #expect(available == 1024)
            #expect(needed > available)
            #expect(result.userMessage.contains("free space"))
            #expect(await checker.verifiedPaths.isEmpty)
            #expect(world.installedApps.isEmpty)
            #expect(world.leftovers.isEmpty)
        }
    }

    // MARK: Quarantine flag

    @Test func quarantinedImageInstallsWhenTheSignatureCheckPasses() async throws {
        try await withEndToEndWorld { world in
            let image = world.fixture(.dmg)
            try await world.quarantine(image)
            #expect(try await world.quarantineValue(of: image) == EndToEndWorld.quarantineValue)
            let installer = AppInstaller.testing(world.install, checker: Self.passing, attachTimeout: .seconds(30))

            try await installer.install(archive: image, kind: .dmg, app: world.target)

            #expect(world.installedApps == ["Fixture.app"])
            #expect(world.leftovers.isEmpty)
        }
    }

    @Test func quarantinedImageIsRefusedWhenTheSignatureCheckFails() async throws {
        try await withEndToEndWorld { world in
            let image = world.fixture(.dmg)
            try await world.quarantine(image)
            let mismatch = SignatureFailure.teamIDMismatch(expected: "ABCDE12345", actual: "ZZZZZ99999")
            let installer = AppInstaller.testing(
                world.install, checker: StubSignatureChecker(.invalid(mismatch)), attachTimeout: .seconds(30)
            )

            let error = await installFailure {
                try await installer.install(archive: image, kind: .dmg, app: world.target)
            }

            #expect(error == .signatureInvalid(mismatch))
            #expect(world.installedApps.isEmpty)
            #expect(world.leftovers.isEmpty)
        }
    }

    // MARK: App already installed

    @Test func installedAppIsReplacedAfterTheUserConfirms() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.zip)
            let old = try world.preinstall()
            let counter = CallCounter()
            let installer = AppInstaller.testing(world.install, checker: Self.passing, replaceCounter: counter)
            let (orchestrator, _) = world.makeOrchestrator(installer: installer)
            #expect(infoValue("CFBundleName", of: old) == "Test")

            let outcome = await orchestrator.install(app)

            #expect(outcome == .completed(.installed))
            #expect(counter.timesCalled == 1)
            #expect(infoValue("CFBundleName", of: old) == "Fixture")
            #expect(world.installedApps == ["Fixture.app"])
        }
    }

    @Test func installedAppStaysAndTheRowReturnsToIdleWhenTheUserDeclinesTheReplace() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.zip)
            let old = try world.preinstall()
            let installer = AppInstaller.testing(world.install, checker: Self.passing, replaceAnswer: false)
            let (orchestrator, _) = world.makeOrchestrator(installer: installer)

            let outcome = await orchestrator.install(app)

            #expect(outcome == .completed(.idle))
            #expect(infoValue("CFBundleName", of: old) == "Test")
            #expect(world.installedApps == ["Fixture.app"])
            #expect(world.leftovers.isEmpty)
        }
    }

    @Test func differentAppAtTheDestinationIsLeftAlone() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.zip)
            let other = try world.preinstall(bundleID: "com.example.SomethingElse")
            let counter = CallCounter()
            let installer = AppInstaller.testing(world.install, checker: Self.passing, replaceCounter: counter)
            let (orchestrator, _) = world.makeOrchestrator(installer: installer)

            let outcome = await orchestrator.install(app)

            #expect(failure(of: outcome) == .install(.differentAppAtDestination(path: other.path)))
            #expect(counter.timesCalled == 0)
            #expect(infoValue("CFBundleIdentifier", of: other) == "com.example.SomethingElse")
        }
    }

    @Test func orchestratorRefusesToInstallAnAppItAlreadyFound() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.dmg)
            let checker = StubSignatureChecker(.valid(EndToEndWorld.expectedTeam))
            let (orchestrator, _) = world.makeOrchestrator(
                installer: AppInstaller.testing(world.install, checker: checker),
                installedBundleIDs: [EndToEndWorld.bundleID]
            )
            await orchestrator.detectInstalled(in: [app])

            let outcome = await orchestrator.install(app)

            #expect(outcome == .refused(.notAllowedInCurrentState))
            #expect(await checker.verifiedPaths.isEmpty)
            #expect(world.leftovers.isEmpty)
        }
    }

    // MARK: App running

    @Test func runningAppQuitsAfterTheUserConfirmsAndIsReplaced() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.zip)
            let old = try world.preinstall()
            let running = FakeRunningApps(running: true)
            let quits = CallCounter()
            let installer = AppInstaller.testing(
                world.install, checker: Self.passing, runningApps: running, quitCounter: quits
            )
            let (orchestrator, _) = world.makeOrchestrator(installer: installer)

            let outcome = await orchestrator.install(app)

            #expect(outcome == .completed(.installed))
            #expect(quits.timesCalled == 1)
            #expect(running.terminateTimeouts.count == 1)
            #expect(infoValue("CFBundleName", of: old) == "Fixture")
        }
    }

    @Test func runningAppIsNotReplacedAndTheRowReturnsToIdleWhenTheUserRefusesToQuit() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.zip)
            let old = try world.preinstall()
            let running = FakeRunningApps(running: true)
            let installer = AppInstaller.testing(
                world.install, checker: Self.passing, runningApps: running, quitAnswer: false
            )
            let (orchestrator, _) = world.makeOrchestrator(installer: installer)

            let outcome = await orchestrator.install(app)

            #expect(outcome == .completed(.idle))
            #expect(running.terminateTimeouts.isEmpty)
            #expect(infoValue("CFBundleName", of: old) == "Test")
            #expect(world.installedApps == ["Fixture.app"])
            #expect(world.leftovers.isEmpty)
        }
    }

    @Test func runningAppThatDoesNotQuitIsNotReplaced() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.zip)
            let old = try world.preinstall()
            let running = FakeRunningApps(running: true, quitSucceeds: false)
            let installer = AppInstaller.testing(world.install, checker: Self.passing, runningApps: running)
            let (orchestrator, _) = world.makeOrchestrator(installer: installer)

            let outcome = await orchestrator.install(app)

            #expect(failure(of: outcome) == .install(.appStillRunning))
            #expect(running.terminateTimeouts.count == 1)
            #expect(infoValue("CFBundleName", of: old) == "Test")
        }
    }

    @Test func uninstallStopsWhenTheUserRefusesToQuitAndRemovesNothing() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.dmg)
            try world.preinstall()
            try world.seedSupportFiles()
            let uninstaller = Uninstaller.testing(
                world.sandbox, trash: world.trash, runningApps: FakeRunningApps(running: true), quitAnswer: false
            )
            let (orchestrator, _) = world.makeOrchestrator(
                uninstaller: uninstaller, installedBundleIDs: [EndToEndWorld.bundleID]
            )
            await orchestrator.detectInstalled(in: [app])

            let outcome = await orchestrator.uninstall(app)

            #expect(outcome == .completed(.installed))
            #expect(world.installedApps == ["Fixture.app"])
            #expect(world.sandbox.exists(world.sandbox.support.appendingPathComponent("SettleInFixture")))
            #expect(world.install.entries(in: world.sandbox.trashFolder).isEmpty)
        }
    }
}
