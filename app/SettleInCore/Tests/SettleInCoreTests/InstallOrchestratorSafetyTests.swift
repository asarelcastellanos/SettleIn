import Foundation
import Testing
@testable import SettleInCore

private struct UninstallRun {
    let outcome: OperationOutcome
    let harness: OrchestratorHarness
    let app: CatalogApp
}

/// Declined questions, an app that outlives its uninstall, a cancel followed by a new request, and the notes
/// that the installer reports.
extension InstallOrchestratorTests {
    struct Safety {
        // MARK: Declined questions

        @Test(arguments: [InstallError.replaceDeclined, .quitDeclined])
        func aDeclinedInstallQuestionReturnsToIdleWithNoFailure(_ declined: InstallError) async throws {
            try await withDownloadScratchRoot { root in
                let harness = OrchestratorHarness(
                    root: root, appInstaller: FakeAppInstaller(result: .failure(declined))
                )
                let app = OrchestratorFixture.app(.dmg)

                let outcome = await harness.orchestrator.install(app)

                #expect(outcome == .completed(.idle))
                #expect(await harness.recorder.sawNames(["downloading", "verifying", "idle"], of: app.id))
                #expect(await harness.orchestrator.log(for: app.id).text.contains("declined by the user"))
                #expect(downloadEntries(in: root).isEmpty)
            }
        }

        private func declinedInstall(locatedAt location: URL, root: URL) async -> (OperationOutcome, StateRecorder) {
            let app = OrchestratorFixture.app(.dmg)
            let harness = OrchestratorHarness(
                root: root,
                appInstaller: FakeAppInstaller(result: .failure(InstallError.replaceDeclined)),
                installedBundleIDs: [app.bundleID.rawValue],
                locatedAt: location
            )
            return (await harness.orchestrator.install(app), harness.recorder)
        }

        @Test func aDeclinedInstallOfAnAppThatIsOnDiskShowsInstalled() async throws {
            try await withDownloadScratchRoot { root in
                let present = root.appendingPathComponent("Fixture.app", isDirectory: true)
                try FileManager.default.createDirectory(at: present, withIntermediateDirectories: false)

                let (outcome, recorder) = await declinedInstall(locatedAt: present, root: root)
                let appID = OrchestratorFixture.app(.dmg).id

                #expect(outcome == .completed(.installed))
                #expect(await recorder.sawNames(["downloading", "verifying", "idle", "installed"], of: appID))
            }
        }

        @Test func aDeclinedInstallStaysIdleWhenTheLocatedPathIsGone() async throws {
            try await withDownloadScratchRoot { root in
                let gone = root.appendingPathComponent("Gone.app", isDirectory: true)

                let (outcome, recorder) = await declinedInstall(locatedAt: gone, root: root)
                let appID = OrchestratorFixture.app(.dmg).id

                #expect(outcome == .completed(.idle))
                #expect(await recorder.sawNames(["downloading", "verifying", "idle"], of: appID))
            }
        }

        @Test func aDeclinedInstallStaysIdleWhenTheLocatedCopyIsInTheTrash() async throws {
            try await withDownloadScratchRoot { root in
                let trashed = root.appendingPathComponent(".Trash/Fixture.app", isDirectory: true)
                try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)

                let (outcome, _) = await declinedInstall(locatedAt: trashed, root: root)

                #expect(outcome == .completed(.idle))
            }
        }

        @Test func aDeclinedInstallCanBeTriedAgain() async throws {
            try await withDownloadScratchRoot { root in
                let harness = OrchestratorHarness(
                    root: root, appInstaller: FakeAppInstaller(result: .failure(InstallError.replaceDeclined))
                )
                let app = OrchestratorFixture.app(.dmg)
                await harness.orchestrator.install(app)

                #expect(await harness.orchestrator.install(app) == .completed(.idle))
                #expect(harness.appInstaller.calls.count == 2)
            }
        }

        @Test func aDeclinedUninstallReturnsToInstalledWithNoFailure() async throws {
            try await withDownloadScratchRoot { root in
                let app = OrchestratorFixture.app(.dmg)
                let harness = OrchestratorHarness(
                    root: root,
                    uninstaller: FakeUninstaller(result: .failure(UninstallError.quitDeclined)),
                    installedBundleIDs: [app.bundleID.rawValue]
                )
                await harness.orchestrator.detectInstalled(in: [app])

                let outcome = await harness.orchestrator.uninstall(app)

                #expect(outcome == .completed(.installed))
                #expect(await harness.recorder.sawNames(["installed", "uninstalling", "installed"], of: app.id))
                #expect(await harness.orchestrator.log(for: app.id).text.contains("declined by the user"))
            }
        }

        @Test func anAppThatDoesNotQuitStillEndsFailed() async throws {
            try await withDownloadScratchRoot { root in
                let harness = OrchestratorHarness(
                    root: root, appInstaller: FakeAppInstaller(result: .failure(InstallError.appStillRunning))
                )
                let app = OrchestratorFixture.app(.dmg)

                #expect(await harness.orchestrator.install(app) == .completed(.failed(.install(.appStillRunning))))
            }
        }

        // MARK: App still present after the uninstall

        private func uninstallOutcome(
            locatedAt location: URL,
            report: UninstallReport = UninstallReport(items: []),
            root: URL
        ) async -> UninstallRun {
            let app = OrchestratorFixture.app(.dmg)
            let harness = OrchestratorHarness(
                root: root,
                uninstaller: FakeUninstaller(result: .success(report)),
                installedBundleIDs: [app.bundleID.rawValue],
                locatedAt: location
            )
            await harness.orchestrator.detectInstalled(in: [app])
            return UninstallRun(outcome: await harness.orchestrator.uninstall(app), harness: harness, app: app)
        }

        @Test func anAppThatLaunchServicesStillFindsOnDiskEndsFailed() async throws {
            try await withDownloadScratchRoot { root in
                let leftover = root.appendingPathComponent("Fixture.app", isDirectory: true)
                try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: false)

                let run = await uninstallOutcome(locatedAt: leftover, root: root)
                let (harness, app) = (run.harness, run.app)

                #expect(run.outcome == .completed(.failed(.stillPresentAfterUninstall)))
                let message = InstallFailure.stillPresentAfterUninstall.userMessage
                #expect(message.contains("removed what the catalog lists but still found the app"))
                #expect(message.contains("by hand"))
                #expect(await harness.recorder.sawNames(["installed", "uninstalling", "failed"], of: app.id))
                #expect(await harness.orchestrator.log(for: app.id).text.contains("the app is still at"))
            }
        }

        @Test func aPathThatIsGoneDoesNotCountAsPresent() async throws {
            try await withDownloadScratchRoot { root in
                let gone = root.appendingPathComponent("Gone.app", isDirectory: true)

                let run = await uninstallOutcome(locatedAt: gone, root: root)

                #expect(run.outcome == .completed(.idle))
            }
        }

        @Test func aCopyInsideATrashFolderDoesNotCountAsPresent() async throws {
            try await withDownloadScratchRoot { root in
                let trashed = root.appendingPathComponent(".Trash/Fixture.app", isDirectory: true)
                try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)

                let run = await uninstallOutcome(locatedAt: trashed, root: root)

                #expect(run.outcome == .completed(.idle))
            }
        }

        @Test func aCopyInsideAVolumeTrashesFolderDoesNotCountAsPresent() async throws {
            try await withDownloadScratchRoot { root in
                let trashed = root.appendingPathComponent(".Trashes/501/Fixture.app", isDirectory: true)
                try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)

                let run = await uninstallOutcome(locatedAt: trashed, root: root)

                #expect(run.outcome == .completed(.idle))
            }
        }

        @Test func pathsLeftAloneStillReportTheMoreSpecificFailure() async throws {
            try await withDownloadScratchRoot { root in
                let leftover = root.appendingPathComponent("Fixture.app", isDirectory: true)
                try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: false)
                let report = UninstallReport(items: [
                    UninstallItem(path: "~/Library/Caches/example", outcome: .refused(reason: "a symbolic link"))
                ])

                let run = await uninstallOutcome(locatedAt: leftover, report: report, root: root)

                #expect(run.outcome == .completed(.failed(.uninstallIncomplete(leftAlone: 1))))
            }
        }

        // MARK: Cancel, then a new request at once

        @Test func aNewInstallRightAfterACancelStillCanBeCancelled() async throws {
            try await withDownloadScratchRoot { root in
                let harness = OrchestratorHarness(root: root, downloader: .hold(progress: nil))
                let app = OrchestratorFixture.app(.dmg)

                for round in 1...10 {
                    let first = Task { await harness.orchestrator.install(app) }
                    #expect(await eventually { harness.downloader.sources.count == 2 * round - 1 })
                    await harness.orchestrator.cancel(appID: app.id)
                    // The second request spins until the first run is over, so it registers while the first
                    // call to `install` is still waiting to resume.
                    let second = Task { () -> OperationOutcome in
                        while true {
                            let outcome = await harness.orchestrator.install(app)
                            if outcome != .refused(.busy) { return outcome }
                            await Task.yield()
                        }
                    }
                    #expect(await eventually { harness.downloader.sources.count == 2 * round })
                    _ = await first.value

                    await harness.orchestrator.cancel(appID: app.id)

                    var finished = false
                    for _ in 0..<300 where !finished {
                        finished = await harness.orchestrator.state(of: app.id) == .idle
                        if !finished { try? await Task.sleep(for: .milliseconds(10)) }
                    }
                    #expect(finished, "round \(round): the second run ignored its cancel")
                    guard finished else { return }
                    #expect(await second.value == .completed(.idle))
                    #expect(await harness.orchestrator.state(of: app.id) == .idle)
                }
            }
        }

        // MARK: Notes from the installer

        @Test func notesFromTheInstallerReachTheLogAndLeaveTheResultAlone() async throws {
            try await withDownloadScratchRoot { root in
                let installer = FakeAppInstaller(notes: ["the disk image was not detached", "the folder stayed"])
                let harness = OrchestratorHarness(root: root, appInstaller: installer)
                let app = OrchestratorFixture.app(.dmg)

                let outcome = await harness.orchestrator.install(app)

                #expect(outcome == .completed(.installed))
                let text = await harness.orchestrator.log(for: app.id).text
                #expect(text.contains("AppInstaller: the disk image was not detached"))
                #expect(text.contains("AppInstaller: the folder stayed"))
            }
        }

        @Test func notesReachTheLogWhenTheInstallFails() async throws {
            try await withDownloadScratchRoot { root in
                let installer = FakeAppInstaller(
                    result: .failure(InstallError.copyFailed(detail: "x")), notes: ["the folder stayed"]
                )
                let harness = OrchestratorHarness(root: root, appInstaller: installer)
                let app = OrchestratorFixture.app(.dmg)

                let outcome = await harness.orchestrator.install(app)

                #expect(outcome == .completed(.failed(.install(.copyFailed(detail: "x")))))
                #expect(await harness.orchestrator.log(for: app.id).text.contains("AppInstaller: the folder stayed"))
            }
        }
    }
}
