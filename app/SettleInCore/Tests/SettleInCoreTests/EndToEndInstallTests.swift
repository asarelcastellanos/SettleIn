import Foundation
import Testing
@testable import SettleInCore

/// The whole install and uninstall path on real fixtures, plus the two negative runs and the real signature check.
extension IntegrationTests {
    private static let team = EndToEndWorld.expectedTeam

    // MARK: Success

    @Test func dmgInstallsAndUninstalls() async throws {
        try await installThenUninstall(.dmg)
    }

    @Test func zipInstallsAndUninstalls() async throws {
        try await installThenUninstall(.zip)
    }

    private func installThenUninstall(_ kind: FixtureKind) async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(kind)
            let checker = StubSignatureChecker(.valid(Self.team))
            let (orchestrator, states) = world.makeOrchestrator(
                installer: AppInstaller.testing(world.install, checker: checker)
            )

            let installed = await orchestrator.install(app)

            #expect(installed == .completed(.installed))
            #expect(world.installedApps == ["Fixture.app"])
            let installedApp = world.applications.appendingPathComponent("Fixture.app")
            #expect(infoValue("CFBundleIdentifier", of: installedApp) == EndToEndWorld.bundleID)
            let verified = await checker.verifiedPaths
            #expect(verified.count == 1)
            #expect(verified.allSatisfy { $0.contains("SettleIn-install-") && !$0.contains("/mnt/") })
            #expect(await checker.expectedTeamIDs == [app.teamID])
            #expect(world.leftovers.isEmpty)
            #expect(await eventually { states.names(of: app.id).last == "installed" })
            #expect(collapsed(states.names(of: app.id)) == ["downloading", "verifying", "installing", "installed"])
            let installLog = await orchestrator.log(for: app.id).text
            #expect(installLog.contains("download matches the pinned SHA-256"))

            try world.seedSupportFiles()
            let removed = await orchestrator.uninstall(app)

            #expect(removed == .completed(.idle))
            #expect(world.installedApps.isEmpty)
            #expect(!world.sandbox.exists(world.sandbox.support.appendingPathComponent("SettleInFixture")))
            #expect(world.install.entries(in: world.sandbox.trashFolder).count == 3)
            #expect(world.sandbox.canariesIntact)
            let removalLog = await orchestrator.log(for: app.id).text
            #expect(removalLog.contains("moved to the Trash"))
            #expect(!removalLog.contains(world.home.path))
        }
    }

    // MARK: Negative runs

    @Test func wrongSHA256RefusesAndInstallsNothing() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.dmg, sha256: String(repeating: "0", count: 64))
            let checker = StubSignatureChecker(.valid(Self.team))
            let installer = AppInstaller.testing(world.install, checker: checker)
            let (orchestrator, _) = world.makeOrchestrator(installer: installer)

            let outcome = await orchestrator.install(app)

            guard case .download(.digestMismatch(let expected, let actual)) = try #require(failure(of: outcome)) else {
                Issue.record("expected a digest mismatch, got \(outcome)")
                return
            }
            #expect(expected.rawValue == String(repeating: "0", count: 64))
            #expect(actual != expected)
            #expect(await checker.verifiedPaths.isEmpty)
            #expect(world.installedApps.isEmpty)
            #expect(world.leftovers.isEmpty)
        }
    }

    @Test func wrongTeamIDRefusesAndInstallsNothing() async throws {
        for kind in [FixtureKind.dmg, .zip] {
            try await withEndToEndWorld { world in
                let app = try world.catalogApp(kind)
                let mismatch = SignatureFailure.teamIDMismatch(expected: "ABCDE12345", actual: "ZZZZZ99999")
                let checker = StubSignatureChecker(.invalid(mismatch))
                let (orchestrator, _) = world.makeOrchestrator(
                    installer: AppInstaller.testing(world.install, checker: checker)
                )

                let outcome = await orchestrator.install(app)

                #expect(failure(of: outcome) == .install(.signatureInvalid(mismatch)))
                #expect(await checker.verifiedPaths.count == 1)
                #expect(world.installedApps.isEmpty)
                #expect(world.leftovers.isEmpty)
            }
        }
    }

    // MARK: Real signature check

    @Test func realVerifierReportsMissingTeamIDOnTheAdHocFixture() async throws {
        try await withEndToEndWorld { world in
            let result = await SignatureVerifier().verifyApp(at: world.fixtureApp, expecting: Self.team)

            #expect(result == .invalid(.teamIDMissing))
        }
    }

    @Test func realVerifierStopsTheInstallWithTeamIDMissing() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.dmg)
            let (orchestrator, _) = world.makeOrchestrator(
                installer: AppInstaller.testing(world.install, checker: SignatureVerifier())
            )

            let outcome = await orchestrator.install(app)

            #expect(failure(of: outcome) == .install(.signatureInvalid(.teamIDMissing)))
            #expect(world.installedApps.isEmpty)
            #expect(world.leftovers.isEmpty)
        }
    }
}
