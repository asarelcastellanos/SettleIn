import Foundation
import Testing
@testable import SettleInCore

struct PackageInstallerTests {
    private let validSignature = PackageFakeVerifier(result: .valid(teamID("EQHXZ8M8AV")))

    private func installer(
        verifier: PackageFakeVerifier? = nil,
        runner: PackageFakeRunner,
        locator: PackageFakeLocator,
        monitor: PackageFakeMonitor = PackageFakeMonitor(runningChecks: .max),
        clock: PackageFakeClock = PackageFakeClock(),
        timeout: Duration = .seconds(600)
    ) -> PackageInstaller {
        PackageInstaller(
            verifier: verifier ?? validSignature, runner: runner, locator: locator,
            monitor: monitor, clock: clock, timeout: timeout
        )
    }

    @Test func failedSignatureEmitsFailedAndNeverOpensThePackage() async {
        let runner = PackageFakeRunner()
        let failure = SignatureFailure.teamIDMismatch(expected: "EQHXZ8M8AV", actual: "AAAAAAAAAA")
        let subject = installer(
            verifier: PackageFakeVerifier(result: .invalid(failure)),
            runner: runner, locator: PackageFakeLocator(appearsAfterChecks: nil)
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.failed(.signature(failure))])
        #expect(await runner.calls.isEmpty)
    }

    @Test func bundleAppearingEmitsWaitingInstallingInstalled() async {
        let runner = PackageFakeRunner(receiptAfterChecks: 2)
        let subject = installer(runner: runner, locator: PackageFakeLocator(appearsAfterChecks: 3))

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installing, .installed])
        #expect(await runner.toolNames.first == "open")
    }

    @Test func installerOpensWithAnArgumentListAndNoShell() async {
        let runner = PackageFakeRunner()
        let subject = installer(runner: runner, locator: PackageFakeLocator(appearsAfterChecks: 1))

        _ = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        let calls = await runner.calls
        #expect(calls.first == PackageFakeRunner.Call(
            tool: "open",
            arguments: ["-a", "/System/Library/CoreServices/Installer.app", "/fixture/path/Some.pkg"]
        ))
        #expect(calls.dropFirst().first?.arguments == ["--pkg-info", "com.example.Some.pkg"])
    }

    @Test func installerQuittingWithNoBundleEmitsCancelled() async {
        let runner = PackageFakeRunner()
        let subject = installer(
            runner: runner, locator: PackageFakeLocator(appearsAfterChecks: nil),
            monitor: PackageFakeMonitor(runningChecks: 3)
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .cancelled])
    }

    @Test func missingBundleEmitsTimedOutAtTheTimeoutOnTheFakeClock() async {
        let clock = PackageFakeClock()
        let subject = installer(
            runner: PackageFakeRunner(), locator: PackageFakeLocator(appearsAfterChecks: nil),
            clock: clock, timeout: .seconds(600)
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .failed(.timedOut)])
        #expect(clock.totalSlept == .seconds(600))
        #expect(clock.sleepCount == 600)
    }

    @Test func bundleWithoutReceiptEmitsTimedOutAfterInstalling() async {
        let subject = installer(
            runner: PackageFakeRunner(receiptAfterChecks: nil),
            locator: PackageFakeLocator(appearsAfterChecks: 1), timeout: .seconds(5)
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installing, .failed(.timedOut)])
    }

    @Test func cancellingTheTaskStopsPollingAndNeverKillsInstaller() async throws {
        let runner = PackageFakeRunner()
        let locator = PackageFakeLocator(appearsAfterChecks: nil)
        let clock = PackageFakeClock(holds: true)
        let subject = installer(runner: runner, locator: locator, clock: clock)
        let stream = subject.install(package: packageFixtureURL, app: packageCatalogApp())

        let reader = Task { await collectStates(stream) }
        try await waitUntil { clock.sleepCount == 1 }
        reader.cancel()
        try await waitUntil { clock.interruptedSleeps == 1 }
        let checksAtCancel = locator.checkCount
        try await Task.sleep(for: .milliseconds(50))

        #expect(locator.checkCount == checksAtCancel)
        #expect(clock.sleepCount == 1)
        #expect(await runner.toolNames == ["open"])
    }

    @Test func alreadyInstalledAppEmitsFailedAndNeverOpensThePackage() async {
        let runner = PackageFakeRunner()
        let subject = installer(runner: runner, locator: PackageFakeLocator(appearsAfterChecks: 0))

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.failed(.alreadyInstalled)])
        #expect(await runner.calls.isEmpty)
    }

    @Test func installerThatDoesNotOpenEmitsFailed() async {
        for runner in [PackageFakeRunner(openExitCode: 1), PackageFakeRunner(throwsOnOpen: true)] {
            let subject = installer(runner: runner, locator: PackageFakeLocator(appearsAfterChecks: nil))

            let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

            #expect(states == [.failed(.installerDidNotOpen)])
        }
    }

    @Test func nonPackageEntryEmitsFailedAndRunsNothing() async throws {
        let runner = PackageFakeRunner()
        let name = try #require(AppBundleName("Some.app"))
        let subject = installer(runner: runner, locator: PackageFakeLocator(appearsAfterChecks: nil))
        let app = packageCatalogApp(install: .zip(appName: name))

        let states = await collectStates(subject.install(package: packageFixtureURL, app: app))

        #expect(states == [.failed(.notAPackageEntry)])
        #expect(await runner.calls.isEmpty)
    }

    @Test func verifierConformanceIsInPlace() {
        let checker: any PackageSignatureChecking = SignatureVerifier(runner: PackageFakeRunner())
        #expect(checker is SignatureVerifier)
    }

    /// Polls for up to five seconds without the fake clock, because the condition depends on real task scheduling.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
