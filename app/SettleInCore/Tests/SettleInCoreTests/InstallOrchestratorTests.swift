import Foundation
import Testing
@testable import SettleInCore

struct InstallOrchestratorTests {
    private static let installPath = ["downloading", "verifying", "installing", "installed"]

    // MARK: Full installs

    @Test func dmgInstallDownloadsThenInstallsThroughVerifying() async throws {
        try await withDownloadScratchRoot { root in
            let harness = OrchestratorHarness(root: root)
            let app = OrchestratorFixture.app(.dmg)

            let outcome = await harness.orchestrator.install(app)

            #expect(outcome == .completed(.installed))
            #expect(await harness.recorder.sawNames(Self.installPath, of: app.id))
            #expect(harness.downloader.sources == [OrchestratorFixture.download("Fixture-1.0.dmg")])
            #expect(harness.downloader.hosts == [app.allowedHosts])
            let call = try #require(harness.appInstaller.calls.first)
            #expect(call.kind == .dmg)
            #expect(call.archiveExisted)
            #expect(call.target.bundleID == app.bundleID)
            #expect(call.target.teamID == app.teamID)
            #expect(harness.packageInstaller.packageExistedAtCall.isEmpty)
            #expect(downloadEntries(in: root).isEmpty)
        }
    }

    @Test func zipInstallDownloadsThenInstallsThroughVerifying() async throws {
        try await withDownloadScratchRoot { root in
            let harness = OrchestratorHarness(root: root)
            let app = OrchestratorFixture.app(.zip)

            let outcome = await harness.orchestrator.install(app)

            #expect(outcome == .completed(.installed))
            #expect(await harness.recorder.sawNames(Self.installPath, of: app.id))
            #expect(harness.appInstaller.calls.map(\.kind) == [.zip])
            #expect(downloadEntries(in: root).isEmpty)
        }
    }

    @Test func pkgInstallKeepsThePackageUntilTheInstallerFinishes() async throws {
        try await withDownloadScratchRoot { root in
            let harness = OrchestratorHarness(root: root)
            let app = OrchestratorFixture.app(.pkg)

            let outcome = await harness.orchestrator.install(app)

            #expect(outcome == .completed(.installed))
            #expect(await harness.recorder.sawNames(Self.installPath, of: app.id))
            #expect(harness.packageInstaller.packageExistedAtCall == [true])
            #expect(harness.appInstaller.calls.isEmpty)
            #expect(downloadEntries(in: root).isEmpty)
        }
    }

    @Test func pkgInstallerThatQuitsWithoutTheAppReturnsToIdle() async throws {
        try await withDownloadScratchRoot { root in
            let harness = OrchestratorHarness(
                root: root,
                packageInstaller: FakePackageInstaller(states: [.waitingForUser, .cancelled])
            )
            let app = OrchestratorFixture.app(.pkg)

            let outcome = await harness.orchestrator.install(app)

            #expect(outcome == .completed(.idle))
            #expect(await harness.recorder.sawNames(["downloading", "verifying", "installing", "idle"], of: app.id))
        }
    }

    @Test func aPerArchEntryDownloadsTheBuildForThisArchitecture() async throws {
        let source = DownloadSource.perArch(
            arm64: OrchestratorFixture.download("arm64.dmg"),
            intel: OrchestratorFixture.download("x86_64.dmg")
        )
        let app = OrchestratorFixture.app(.dmg, source: source)
        try await withDownloadScratchRoot { root in
            let arm = OrchestratorHarness(root: root, architecture: .arm64)
            await arm.orchestrator.install(app)
            #expect(arm.downloader.sources == [OrchestratorFixture.download("arm64.dmg")])

            let intel = OrchestratorHarness(root: root, architecture: .intel)
            await intel.orchestrator.install(app)
            #expect(intel.downloader.sources == [OrchestratorFixture.download("x86_64.dmg")])
        }
    }

    @Test func aFailedAppCanBeInstalledAgain() async throws {
        try await withDownloadScratchRoot { root in
            let failure = DownloadError.transferFailed(code: -1009)
            let harness = OrchestratorHarness(root: root, downloader: .failOnce(failure))
            let app = OrchestratorFixture.app(.dmg)

            #expect(await harness.orchestrator.install(app) == .completed(.failed(.download(failure))))
            #expect(await harness.orchestrator.install(app) == .completed(.installed))
            #expect(harness.downloader.sources.count == 2)
        }
    }

    // MARK: Uninstall

    @Test func uninstallRemovesAnInstalledAppAndReturnsToIdle() async throws {
        try await withDownloadScratchRoot { root in
            let app = OrchestratorFixture.app(.dmg)
            let harness = OrchestratorHarness(root: root, installedBundleIDs: [app.bundleID.rawValue])
            await harness.orchestrator.detectInstalled(in: [app])
            #expect(await harness.orchestrator.state(of: app.id) == .installed)

            let outcome = await harness.orchestrator.uninstall(app)

            #expect(outcome == .completed(.idle))
            #expect(harness.uninstaller.appIDs == [app.id])
            #expect(await harness.recorder.sawNames(["installed", "uninstalling", "idle"], of: app.id))
        }
    }

    @Test func uninstallThatLeavesPathsAloneEndsFailed() async throws {
        let report = UninstallReport(items: [
            UninstallItem(path: "/Applications/Fixture.app", outcome: .trashed),
            UninstallItem(path: "~/Library/Caches/example", outcome: .refused(reason: "a symbolic link"))
        ])
        try await withDownloadScratchRoot { root in
            let app = OrchestratorFixture.app(.pkg)
            let harness = OrchestratorHarness(
                root: root,
                uninstaller: FakeUninstaller(result: .success(report)),
                installedBundleIDs: [app.bundleID.rawValue]
            )
            await harness.orchestrator.detectInstalled(in: [app])

            let outcome = await harness.orchestrator.uninstall(app)

            #expect(outcome == .completed(.failed(.uninstallIncomplete(leftAlone: 1))))
        }
    }

    // MARK: Launch detection and refusals

    @Test func launchDetectionMarksOnlyAppsThatLaunchServicesFinds() async throws {
        try await withDownloadScratchRoot { root in
            let found = OrchestratorFixture.app(.dmg, id: "found", bundleID: "com.example.Found")
            let missing = OrchestratorFixture.app(.zip, id: "missing", bundleID: "com.example.Missing")
            let harness = OrchestratorHarness(root: root, installedBundleIDs: [found.bundleID.rawValue])
            await harness.orchestrator.detectInstalled(in: [found, missing])
            #expect(await harness.orchestrator.state(of: found.id) == .installed)
            #expect(await harness.orchestrator.state(of: missing.id) == .idle)
        }
    }

    @Test func installingAnInstalledAppIsRefused() async throws {
        try await withDownloadScratchRoot { root in
            let app = OrchestratorFixture.app(.dmg)
            let harness = OrchestratorHarness(root: root, installedBundleIDs: [app.bundleID.rawValue])
            await harness.orchestrator.detectInstalled(in: [app])

            let outcome = await harness.orchestrator.install(app)

            #expect(outcome == .refused(.notAllowedInCurrentState))
            #expect(await harness.orchestrator.state(of: app.id) == .installed)
            #expect(harness.downloader.sources.isEmpty)
        }
    }

    @Test func uninstallingAnIdleAppIsRefused() async throws {
        try await withDownloadScratchRoot { root in
            let harness = OrchestratorHarness(root: root)
            let app = OrchestratorFixture.app(.dmg)
            #expect(await harness.orchestrator.uninstall(app) == .refused(.notAllowedInCurrentState))
            #expect(harness.uninstaller.appIDs.isEmpty)
        }
    }

    @Test func aSecondRequestOnABusyAppIsRefusedAndTheFirstRunIsUnaffected() async throws {
        try await withDownloadScratchRoot { root in
            let gate = OrchestratorGate()
            let harness = OrchestratorHarness(root: root, downloader: .gated(gate))
            let app = OrchestratorFixture.app(.dmg)
            let first = Task { await harness.orchestrator.install(app) }
            #expect(await eventually { !harness.downloader.sources.isEmpty })

            #expect(await harness.orchestrator.install(app) == .refused(.busy))
            #expect(await harness.orchestrator.uninstall(app) == .refused(.busy))
            #expect(await harness.orchestrator.state(of: app.id) == .downloading(progress: nil))
            #expect(harness.downloader.sources.count == 1)
            #expect(harness.uninstaller.appIDs.isEmpty)

            await gate.open()
            #expect(await first.value == .completed(.installed))
            #expect(harness.appInstaller.calls.count == 1)
            #expect(await harness.recorder.sawNames(Self.installPath, of: app.id))
        }
    }

    @Test func differentAppsRunAtTheSameTime() async throws {
        try await withDownloadScratchRoot { root in
            let gate = OrchestratorGate()
            let harness = OrchestratorHarness(root: root, downloader: .gated(gate))
            let one = OrchestratorFixture.app(.dmg, id: "one")
            let two = OrchestratorFixture.app(.zip, id: "two")
            let first = Task { await harness.orchestrator.install(one) }
            let second = Task { await harness.orchestrator.install(two) }
            #expect(await eventually { harness.downloader.sources.count == 2 })

            await gate.open()
            #expect(await first.value == .completed(.installed))
            #expect(await second.value == .completed(.installed))
        }
    }
}
