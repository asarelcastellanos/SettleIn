import Foundation
import Testing
@testable import SettleInCore

/// The pkg flow up to the point where `open` would run. The fake runner answers `open` and `pkgutil`, so
/// Installer.app never starts and nothing asks for a password.
extension IntegrationTests {
    private static let installerApp = "/System/Library/CoreServices/Installer.app"

    private func packageInstaller(
        verifier: any PackageSignatureChecking,
        runner: PackageFakeRunner,
        appearsAfterChecks: Int? = nil,
        installerRunningChecks: Int = .max
    ) -> PackageInstaller {
        PackageInstaller(
            verifier: verifier, runner: runner,
            locator: PackageFakeLocator(appearsAfterChecks: appearsAfterChecks),
            monitor: PackageFakeMonitor(runningChecks: installerRunningChecks),
            clock: PackageFakeClock()
        )
    }

    @Test(.timeLimit(.minutes(1))) func unsignedPackageIsRefusedBeforeInstallerOpens() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.pkg)
            let runner = PackageFakeRunner()
            let package = packageInstaller(verifier: SignatureVerifier(), runner: runner)
            let (orchestrator, _) = world.makeOrchestrator(package: package)

            let outcome = await orchestrator.install(app)

            #expect(failure(of: outcome) == .package(.signature(.unsigned)))
            #expect(await runner.calls.isEmpty)
            #expect(world.leftovers.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func verifiedPackageOpensInstallerWithAnArgumentList() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.pkg)
            let runner = PackageFakeRunner(receiptAfterChecks: 2)
            let package = packageInstaller(
                verifier: PackageFakeVerifier(result: .valid(EndToEndWorld.expectedTeam)),
                runner: runner, appearsAfterChecks: 3
            )
            let (orchestrator, states) = world.makeOrchestrator(package: package)

            let outcome = await orchestrator.install(app)

            #expect(outcome == .completed(.installed))
            let calls = await runner.calls
            let open = try #require(calls.first { $0.tool == "open" })
            #expect(open.arguments.count == 3)
            #expect(Array(open.arguments.prefix(2)) == ["-a", Self.installerApp])
            #expect(open.arguments.last?.hasPrefix(world.downloads.path) == true)
            #expect(open.arguments.last?.hasSuffix("/Fixture.pkg") == true)
            #expect(calls.filter { $0.tool != "open" }.allSatisfy { $0.tool == "pkgutil" })
            #expect(await eventually { states.names(of: app.id).last == "installed" })
            #expect(world.installedApps.isEmpty)
            #expect(world.leftovers.isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func userCancellingInstallerEndsIdleWithNothingInstalled() async throws {
        try await withEndToEndWorld { world in
            let app = try world.catalogApp(.pkg)
            let runner = PackageFakeRunner()
            let package = packageInstaller(
                verifier: PackageFakeVerifier(result: .valid(EndToEndWorld.expectedTeam)),
                runner: runner, installerRunningChecks: 0
            )
            let (orchestrator, states) = world.makeOrchestrator(package: package)

            let outcome = await orchestrator.install(app)

            #expect(outcome == .completed(.idle))
            #expect(await runner.toolNames == ["pkgutil", "open"])
            #expect(await eventually { states.names(of: app.id).last == "idle" })
            let log = await orchestrator.log(for: app.id).text
            #expect(log.contains("Installer.app is not running and the app did not appear"))
            #expect(world.installedApps.isEmpty)
            #expect(world.leftovers.isEmpty)
        }
    }
}
