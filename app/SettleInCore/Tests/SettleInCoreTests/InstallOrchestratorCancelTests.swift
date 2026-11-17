import Foundation
import Testing
@testable import SettleInCore

extension InstallOrchestratorTests {
    struct Cancelling {
        @Test func cancellingADownloadEndsIdleWithNoTemporaryDirectory() async throws {
            try await withDownloadScratchRoot { root in
                let installer = FakeAppInstaller()
                let harness = OrchestratorHarness(root: root, downloader: .hold(progress: 0.4), appInstaller: installer)
                let app = OrchestratorFixture.app(.dmg)
                let run = Task { await harness.orchestrator.install(app) }
                #expect(await eventually { downloadEntries(in: root).count == 1 })

                await harness.orchestrator.cancel(appID: app.id)

                #expect(await run.value == .completed(.idle))
                #expect(await harness.orchestrator.state(of: app.id) == .idle)
                #expect(downloadEntries(in: root).isEmpty)
                #expect(installer.calls.isEmpty)
                #expect(await eventually { harness.recorder.names(of: app.id).last == "idle" })
            }
        }

        @Test func aCancelledPkgDownloadNeverOpensTheInstaller() async throws {
            try await withDownloadScratchRoot { root in
                let packageInstaller = FakePackageInstaller()
                let harness = OrchestratorHarness(
                    root: root,
                    downloader: .hold(progress: nil),
                    packageInstaller: packageInstaller
                )
                let app = OrchestratorFixture.app(.pkg)
                let run = Task { await harness.orchestrator.install(app) }
                #expect(await eventually { downloadEntries(in: root).count == 1 })

                await harness.orchestrator.cancel(appID: app.id)

                #expect(await run.value == .completed(.idle))
                #expect(packageInstaller.packageExistedAtCall.isEmpty)
                #expect(downloadEntries(in: root).isEmpty)
            }
        }

        @Test func downloadProgressReachesTheState() async throws {
            try await withDownloadScratchRoot { root in
                let harness = OrchestratorHarness(root: root, downloader: .hold(progress: 0.4))
                let app = OrchestratorFixture.app(.dmg)
                let run = Task { await harness.orchestrator.install(app) }

                let reached = await eventually {
                    harness.recorder.states(of: app.id).contains(.downloading(progress: 0.4))
                }
                #expect(reached)

                await harness.orchestrator.cancel(appID: app.id)
                _ = await run.value
            }
        }

        @Test func cancellingAnIdleAppDoesNothing() async throws {
            try await withDownloadScratchRoot { root in
                let harness = OrchestratorHarness(root: root)
                let app = OrchestratorFixture.app(.dmg)
                await harness.orchestrator.cancel(appID: app.id)
                #expect(await harness.orchestrator.state(of: app.id) == .idle)
                #expect(await harness.orchestrator.log(for: app.id).entries.isEmpty)
            }
        }

        @Test func aCancelledAppCanBeInstalledAgain() async throws {
            try await withDownloadScratchRoot { root in
                let harness = OrchestratorHarness(root: root, downloader: .hold(progress: nil))
                let app = OrchestratorFixture.app(.dmg)
                let run = Task { await harness.orchestrator.install(app) }
                #expect(await eventually { downloadEntries(in: root).count == 1 })
                await harness.orchestrator.cancel(appID: app.id)
                _ = await run.value

                let again = Task { await harness.orchestrator.install(app) }
                #expect(await eventually { harness.downloader.sources.count == 2 })
                #expect(await harness.orchestrator.state(of: app.id) == .downloading(progress: nil))
                await harness.orchestrator.cancel(appID: app.id)
                #expect(await again.value == .completed(.idle))
            }
        }
    }
}

/// The real downloader runs here against the stubbed network, so a leaked temporary directory shows up in the
/// scratch root. The extension joins the serialized `DownloaderTests` suite because the stub keeps global state.
extension DownloaderTests {
    @Test func cancellingAnOrchestratedInstallRemovesTheRealDownloadDirectory() async throws {
        let address = "https://downloads.example.com/Fixture-1.0.dmg"
        DownloadStub.reset(routes: [
            address: .body(status: 200, chunks: [Data(count: 65_536)], contentLength: 1_048_576, hold: true)
        ])
        let app = OrchestratorFixture.app(.dmg)
        try await withDownloadScratchRoot { root in
            let downloader = Downloader(configuration: DownloadStub.configuration(), temporaryRoot: root)
            let installer = FakeAppInstaller()
            let orchestrator = InstallOrchestrator(
                downloader: downloader,
                appInstaller: installer,
                uninstaller: FakeUninstaller(),
                locator: FakeBundleLocator(found: []),
                architecture: .arm64
            )
            let run = Task { await orchestrator.install(app) }
            #expect(await eventually { downloadEntries(in: root).count == 1 })

            await orchestrator.cancel(appID: app.id)

            #expect(await run.value == .completed(.idle))
            #expect(downloadEntries(in: root).isEmpty)
            #expect(installer.calls.isEmpty)
        }
    }

    @Test func aWrongSHA256EndsFailedWithAMessageAndNoInstallerCall() async throws {
        let address = "https://downloads.example.com/Fixture-1.0.dmg"
        DownloadStub.reset(routes: [
            address: .body(status: 200, chunks: [Data("hello".utf8)], contentLength: 5, hold: false)
        ])
        let app = OrchestratorFixture.app(.dmg)
        try await withDownloadScratchRoot { root in
            let downloader = Downloader(configuration: DownloadStub.configuration(), temporaryRoot: root)
            let installer = FakeAppInstaller()
            let orchestrator = InstallOrchestrator(
                downloader: downloader,
                appInstaller: installer,
                uninstaller: FakeUninstaller(),
                locator: FakeBundleLocator(found: []),
                architecture: .arm64
            )

            let outcome = await orchestrator.install(app)

            guard case .completed(.failed(let failure)) = outcome, case .download(.digestMismatch) = failure else {
                Issue.record("expected a digest mismatch, got \(outcome)")
                return
            }
            #expect(failure.userMessage.contains("SHA-256"))
            #expect(installer.calls.isEmpty)
            #expect(downloadEntries(in: root).isEmpty)
            #expect(await orchestrator.log(for: app.id).text.contains("state: downloading -> failed"))
        }
    }
}
