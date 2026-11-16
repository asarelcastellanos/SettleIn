import Foundation
import Testing
@testable import SettleInCore

extension InstallOrchestratorTests {
    struct Failures {
        private static let mismatch = SignatureFailure.teamIDMismatch(expected: "EQHXZ8M8AV", actual: "ABCDEFGHIJ")

        /// Runs one install and checks that it ended in `expected`, with a message the user can read, and that the
        /// app went through exactly the states in `path`.
        private func expectInstallFails(
            _ kind: OrchestratorFixture.Kind,
            harness make: (URL) -> OrchestratorHarness,
            with expected: InstallFailure,
            path: [String],
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            try await withDownloadScratchRoot { root in
                let harness = make(root)
                let app = OrchestratorFixture.app(kind)

                let outcome = await harness.orchestrator.install(app)

                #expect(outcome == .completed(.failed(expected)), sourceLocation: sourceLocation)
                #expect(!expected.userMessage.isEmpty, sourceLocation: sourceLocation)
                #expect(await harness.recorder.sawNames(path, of: app.id), sourceLocation: sourceLocation)
                #expect(downloadEntries(in: root).isEmpty, sourceLocation: sourceLocation)
            }
        }

        // MARK: Download step

        @Test func aFailedDownloadEndsFailedAndNeverReachesAnInstaller() async throws {
            let expected = try #require(SHA256Digest(OrchestratorFixture.sha256))
            let actual = try #require(SHA256Digest(String(repeating: "c", count: 64)))
            let failure = DownloadError.digestMismatch(expected: expected, actual: actual)
            let installer = FakeAppInstaller()
            try await expectInstallFails(
                .dmg,
                harness: { OrchestratorHarness(root: $0, downloader: .fail(failure), appInstaller: installer) },
                with: .download(failure),
                path: ["downloading", "failed"]
            )
            #expect(installer.calls.isEmpty)
        }

        @Test func aFailedPkgDownloadNeverOpensTheInstaller() async throws {
            let packageInstaller = FakePackageInstaller()
            try await expectInstallFails(
                .pkg,
                harness: { OrchestratorHarness(root: $0, downloader: .fail(DownloadError.unexpectedStatus(404)),
                                               packageInstaller: packageInstaller) },
                with: .download(.unexpectedStatus(404)),
                path: ["downloading", "failed"]
            )
            #expect(packageInstaller.packageExistedAtCall.isEmpty)
        }

        // MARK: Verification step

        @Test(arguments: [OrchestratorFixture.Kind.dmg, .zip])
        func aSignatureFailureOfTheStagedCopyEndsFailed(_ kind: OrchestratorFixture.Kind) async throws {
            let failure = InstallError.signatureInvalid(Self.mismatch)
            try await expectInstallFails(
                kind,
                harness: { OrchestratorHarness(root: $0, appInstaller: FakeAppInstaller(result: .failure(failure))) },
                with: .install(failure),
                path: ["downloading", "verifying", "failed"]
            )
        }

        @Test func aPackageSignatureFailureEndsFailedWhileVerifying() async throws {
            let failure = PackageInstallFailure.signature(Self.mismatch)
            try await expectInstallFails(
                .pkg,
                harness: {
                    OrchestratorHarness(root: $0, packageInstaller: FakePackageInstaller(states: [.failed(failure)]))
                },
                with: .package(failure),
                path: ["downloading", "verifying", "failed"]
            )
        }

        // MARK: Install step

        @Test func aCopyFailureEndsFailed() async throws {
            let failure = InstallError.copyFailed(detail: "The ditto tool did not start.")
            try await expectInstallFails(
                .zip,
                harness: { OrchestratorHarness(root: $0, appInstaller: FakeAppInstaller(result: .failure(failure))) },
                with: .install(failure),
                path: ["downloading", "verifying", "failed"]
            )
        }

        @Test func aPackageInstallTimeoutEndsFailedWhileInstalling() async throws {
            try await expectInstallFails(
                .pkg,
                harness: {
                    OrchestratorHarness(
                        root: $0,
                        packageInstaller: FakePackageInstaller(
                            states: [.waitingForUser, .installing, .failed(.timedOut)]
                        )
                    )
                },
                with: .package(.timedOut),
                path: ["downloading", "verifying", "installing", "failed"]
            )
        }

        @Test func aPackageStreamThatEndsWithoutAResultEndsFailed() async throws {
            try await expectInstallFails(
                .pkg,
                harness: {
                    OrchestratorHarness(root: $0, packageInstaller: FakePackageInstaller(states: [.waitingForUser]))
                },
                with: .interrupted,
                path: ["downloading", "verifying", "installing", "failed"]
            )
        }

        @Test func anErrorTheEngineDoesNotDeclareEndsFailedWithAGenericMessage() async throws {
            try await expectInstallFails(
                .dmg,
                harness: {
                    let installer = FakeAppInstaller(result: .failure(CocoaError(.fileReadUnknown)))
                    return OrchestratorHarness(root: $0, appInstaller: installer)
                },
                with: .unexpected,
                path: ["downloading", "verifying", "failed"]
            )
        }

        // MARK: Uninstall step

        @Test func anUninstallErrorEndsFailed() async throws {
            try await withDownloadScratchRoot { root in
                let app = OrchestratorFixture.app(.dmg)
                let harness = OrchestratorHarness(
                    root: root,
                    uninstaller: FakeUninstaller(result: .failure(UninstallError.appStillRunning)),
                    installedBundleIDs: [app.bundleID.rawValue]
                )
                await harness.orchestrator.detectInstalled(in: [app])

                let outcome = await harness.orchestrator.uninstall(app)

                #expect(outcome == .completed(.failed(.uninstall(.appStillRunning))))
                #expect(await harness.recorder.sawNames(["installed", "uninstalling", "failed"], of: app.id))
            }
        }

        @Test func aFailedUninstallCanBeTriedAgain() async throws {
            try await withDownloadScratchRoot { root in
                let app = OrchestratorFixture.app(.dmg)
                let harness = OrchestratorHarness(
                    root: root,
                    uninstaller: FakeUninstaller(result: .failure(UninstallError.appStillRunning)),
                    installedBundleIDs: [app.bundleID.rawValue]
                )
                await harness.orchestrator.detectInstalled(in: [app])
                await harness.orchestrator.uninstall(app)

                #expect(await harness.orchestrator.uninstall(app) == .completed(.failed(.uninstall(.appStillRunning))))
                #expect(harness.uninstaller.appIDs.count == 2)
            }
        }
    }
}
