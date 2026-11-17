import Foundation
import Testing
@testable import SettleInCore

/// The endings of a pkg install as the orchestrator records them, and the way out of the wait.
extension InstallOrchestratorTests {
    @Suite(.timeLimit(.minutes(1)))
    struct PackageEndings {
        private func install(
            _ states: [PackageInstallState],
            root: URL
        ) async -> (outcome: OperationOutcome, text: String) {
            let app = OrchestratorFixture.app(.pkg)
            let harness = OrchestratorHarness(root: root, packageInstaller: FakePackageInstaller(states: states))
            let outcome = await harness.orchestrator.install(app)
            return (outcome, await harness.orchestrator.log(for: app.id).text)
        }

        // MARK: Log text for each ending

        @Test func aNewReceiptIsLoggedAsANewReceipt() async throws {
            try await withDownloadScratchRoot { root in
                let result = await install([.waitingForUser, .installing, .installed], root: root)

                #expect(result.outcome == .completed(.installed))
                #expect(result.text.contains("the package receipt is new"))
                #expect(!result.text.contains("no new receipt appeared"))
            }
        }

        @Test func anInstallerThatClosedWithTheAppPresentIsLoggedAsExactlyThat() async throws {
            try await withDownloadScratchRoot { root in
                let result = await install([.waitingForUser, .installedAfterInstallerClosed], root: root)

                #expect(result.outcome == .completed(.installed))
                #expect(result.text.contains("Installer.app is closed and the app is present"))
                #expect(result.text.contains("no new receipt appeared"))
                #expect(!result.text.contains("receipt is new"))
                #expect(!result.text.contains("app and receipt found"))
            }
        }

        @Test func aCancelledPollIsLoggedWithoutSayingInstallerQuit() async throws {
            try await withDownloadScratchRoot { root in
                let result = await install([.waitingForUser, .cancelled], root: root)

                #expect(result.outcome == .completed(.idle))
                #expect(result.text.contains("Installer.app is not running and the app did not appear"))
            }
        }

        // MARK: Stop waiting

        /// The outcome of the run, or nil when it has not ended after five seconds. A run that never ends fails
        /// the test and does not hang it.
        private func settled(_ run: Task<OperationOutcome, Never>) async -> OperationOutcome? {
            let box = OutcomeBox()
            Task { box.set(await run.value) }
            _ = await eventually { box.value != nil }
            return box.value
        }

        private func holdingHarness(root: URL, locatedAt location: URL?) -> (OrchestratorHarness, CatalogApp) {
            let app = OrchestratorFixture.app(.pkg)
            let harness = OrchestratorHarness(
                root: root,
                packageInstaller: FakePackageInstaller(states: [.waitingForUser, .installing], holds: true),
                installedBundleIDs: location == nil ? [] : [app.bundleID.rawValue],
                locatedAt: location
            )
            return (harness, app)
        }

        @Test func stoppingTheWaitStopsThePollAndReturnsToIdleWhenTheAppIsNotThere() async throws {
            try await withDownloadScratchRoot { root in
                let (harness, app) = holdingHarness(root: root, locatedAt: nil)
                let run = Task { await harness.orchestrator.install(app) }
                #expect(await harness.recorder.sawNames(["downloading", "verifying", "installing"], of: app.id))

                await harness.orchestrator.cancel(appID: app.id)

                #expect(await settled(run) == .completed(.idle))
                #expect(harness.packageInstaller.wasStopped)
                #expect(await harness.recorder.sawNames(["downloading", "verifying", "installing", "idle"], of: app.id))
                let text = await harness.orchestrator.log(for: app.id).text
                #expect(text.contains("stop waiting requested"))
                #expect(text.contains("stopped waiting for Installer.app"))
                #expect(!text.contains("failed"))
                #expect(downloadEntries(in: root).isEmpty)
            }
        }

        @Test func stoppingTheWaitShowsInstalledWhenTheAppIsOnDisk() async throws {
            try await withDownloadScratchRoot { root in
                let present = root.appendingPathComponent("Fixture.app", isDirectory: true)
                try FileManager.default.createDirectory(at: present, withIntermediateDirectories: false)
                let (harness, app) = holdingHarness(root: root, locatedAt: present)
                let run = Task { await harness.orchestrator.install(app) }
                #expect(await harness.recorder.sawNames(["downloading", "verifying", "installing"], of: app.id))

                await harness.orchestrator.cancel(appID: app.id)

                #expect(await settled(run) == .completed(.installed))
                let names = ["downloading", "verifying", "installing", "idle", "installed"]
                #expect(await harness.recorder.sawNames(names, of: app.id))
            }
        }

        @Test func stoppingTheWaitStaysIdleWhenTheLocatedCopyIsInTheTrash() async throws {
            try await withDownloadScratchRoot { root in
                let trashed = root.appendingPathComponent(".Trash/Fixture.app", isDirectory: true)
                try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
                let (harness, app) = holdingHarness(root: root, locatedAt: trashed)
                let run = Task { await harness.orchestrator.install(app) }
                #expect(await harness.recorder.sawNames(["downloading", "verifying", "installing"], of: app.id))

                await harness.orchestrator.cancel(appID: app.id)

                #expect(await settled(run) == .completed(.idle))
            }
        }

        @Test func aStoppedWaitCanBeInstalledAgain() async throws {
            try await withDownloadScratchRoot { root in
                let (harness, app) = holdingHarness(root: root, locatedAt: nil)
                let first = Task { await harness.orchestrator.install(app) }
                #expect(await harness.recorder.sawNames(["downloading", "verifying", "installing"], of: app.id))
                await harness.orchestrator.cancel(appID: app.id)
                _ = await settled(first)

                let second = Task { await harness.orchestrator.install(app) }
                #expect(await eventually { harness.recorder.names(of: app.id).count == 7 })
                await harness.orchestrator.cancel(appID: app.id)
                #expect(await settled(second) == .completed(.idle))
            }
        }
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: OperationOutcome?
    func set(_ value: OperationOutcome) { lock.withLock { outcome = value } }
    var value: OperationOutcome? { lock.withLock { outcome } }
}
