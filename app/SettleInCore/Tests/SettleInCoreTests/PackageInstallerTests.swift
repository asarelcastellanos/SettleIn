import Foundation
import Testing
@testable import SettleInCore

@Suite(.timeLimit(.minutes(1)))
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
        #expect(await runner.toolNames.prefix(2) == ["pkgutil", "open"], "the receipt is read before the open")
    }

    @Test func installerOpensWithAnArgumentListAndNoShell() async {
        let runner = PackageFakeRunner(receiptAfterChecks: 1)
        let subject = installer(runner: runner, locator: PackageFakeLocator(appearsAfterChecks: 1))

        _ = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        let calls = await runner.calls
        #expect(calls.first?.arguments == ["--pkg-info", "com.example.Some.pkg"])
        #expect(calls.dropFirst().first == PackageFakeRunner.Call(
            tool: "open",
            arguments: ["-a", "/System/Library/CoreServices/Installer.app", "/fixture/path/Some.pkg"]
        ))
        #expect(calls.dropFirst(2).first?.arguments == ["--pkg-info", "com.example.Some.pkg"])
    }

    @Test func installerQuittingWithNoBundleEmitsCancelledAfterThreeAbsentPolls() async {
        let clock = PackageFakeClock()
        let subject = installer(
            runner: PackageFakeRunner(), locator: PackageFakeLocator(appearsAfterChecks: nil),
            monitor: PackageFakeMonitor(runningChecks: 3), clock: clock
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .cancelled])
        #expect(clock.sleepCount == 5, "three polls with Installer.app running, then three without")
    }

    @Test func installerThatAppearsLateIsNotTakenForACancel() async {
        // Closed, closed, open, open, then closed for good. Two absent polls are not enough, and the count restarts
        // when Installer.app shows up.
        let clock = PackageFakeClock()
        let subject = installer(
            runner: PackageFakeRunner(), locator: PackageFakeLocator(appearsAfterChecks: nil),
            monitor: PackageFakeMonitor(script: [false, false, true, true], afterScript: false), clock: clock
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .cancelled])
        #expect(clock.sleepCount == 6)
    }

    @Test func installerThatWasNeverSeenIsNotTakenForACancelBeforeTenAbsentPolls() async {
        let clock = PackageFakeClock()
        let subject = installer(
            runner: PackageFakeRunner(), locator: PackageFakeLocator(appearsAfterChecks: nil),
            monitor: PackageFakeMonitor(script: [], afterScript: false), clock: clock
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .cancelled])
        #expect(clock.sleepCount == 9)
    }

    @Test func installerSeenAfterNineAbsentPollsNeedsOnlyThreeMoreToCancel() async {
        // Nine polls without Installer.app, one with it, then closed for good. Once it has been seen, three
        // absent polls in a row are enough.
        let clock = PackageFakeClock()
        let script = Array(repeating: false, count: 9) + [true]
        let subject = installer(
            runner: PackageFakeRunner(), locator: PackageFakeLocator(appearsAfterChecks: nil),
            monitor: PackageFakeMonitor(script: script, afterScript: false), clock: clock
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .cancelled])
        #expect(clock.sleepCount == 12)
    }

    @Test func installerThatKeepsReopeningEmitsTimedOutAfterTheClosedPollsAddUp() async {
        // Closed twice, then open, again and again. Three closed polls never come in a row, so only the timeout
        // can end the run. The eleventh closed poll is poll 16, and it ends the run.
        let clock = PackageFakeClock()
        let script = Array(repeating: [false, false, true], count: 10).flatMap { $0 }
        let subject = installer(
            runner: PackageFakeRunner(), locator: PackageFakeLocator(appearsAfterChecks: 1),
            monitor: PackageFakeMonitor(script: script, afterScript: true), clock: clock, timeout: .seconds(10)
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installing, .failed(.timedOut)])
        #expect(clock.sleepCount == 15)
    }

    @Test func timeoutNeverFiresWhileInstallerIsOpen() async {
        // Installer.app stays open for 100 polls, which would pass the 5 second timeout if open polls counted.
        // After it closes, three closed polls in a row end the run as installed.
        let clock = PackageFakeClock()
        let subject = installer(
            runner: PackageFakeRunner(), locator: PackageFakeLocator(appearsAfterChecks: 1),
            monitor: PackageFakeMonitor(runningChecks: 100), clock: clock, timeout: .seconds(5)
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installing, .installedAfterInstallerClosed])
        #expect(clock.sleepCount == 102)
    }

    @Test func installerThatReopensIsNotTimedOutWhileItIsOpen() async {
        // Five closed polls use the whole timeout, but no three come in a row. Poll 8 finds Installer.app open
        // again, and the run goes on. Poll 9 finds it closed and reports timedOut.
        let clock = PackageFakeClock()
        let script = [false, false, true, false, false, true, false, true, false]
        let subject = installer(
            runner: PackageFakeRunner(), locator: PackageFakeLocator(appearsAfterChecks: 1),
            monitor: PackageFakeMonitor(script: script, afterScript: true), clock: clock, timeout: .seconds(5)
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installing, .failed(.timedOut)])
        #expect(clock.sleepCount == 8)
    }

    // MARK: Installer closed with the bundle present

    @Test func bundleWithoutReceiptEmitsInstalledAfterInstallerStaysClosedForThreePolls() async {
        let clock = PackageFakeClock()
        let subject = installer(
            runner: PackageFakeRunner(receiptAfterChecks: nil),
            locator: PackageFakeLocator(appearsAfterChecks: 1),
            monitor: PackageFakeMonitor(runningChecks: 0), clock: clock, timeout: .seconds(5)
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installing, .installedAfterInstallerClosed])
        #expect(clock.sleepCount == 2)
    }

    @Test func twoClosedPollsWithTheBundlePresentAreNotEnough() async {
        // Closed, closed, open, then closed for good. The count restarts when Installer.app shows up.
        let clock = PackageFakeClock()
        let subject = installer(
            runner: PackageFakeRunner(receiptAfterChecks: nil),
            locator: PackageFakeLocator(appearsAfterChecks: 1),
            monitor: PackageFakeMonitor(script: [false, false, true], afterScript: false), clock: clock
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installing, .installedAfterInstallerClosed])
        #expect(clock.sleepCount == 5)
    }

    // MARK: Receipt that existed before the run

    @Test func aNewReceiptEndsTheRunWhileInstallerIsStillOpen() async {
        let clock = PackageFakeClock()
        let subject = installer(
            runner: PackageFakeRunner(receiptAfterChecks: 1),
            locator: PackageFakeLocator(appearsAfterChecks: 1), clock: clock
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installed])
        #expect(clock.sleepCount == 0)
    }

    @Test func anOldReceiptDoesNotEndTheRunWhileInstallerIsOpen() async {
        let clock = PackageFakeClock()
        let subject = installer(
            runner: PackageFakeRunner(receiptAfterChecks: 0),
            locator: PackageFakeLocator(appearsAfterChecks: 1),
            monitor: PackageFakeMonitor(runningChecks: 4), clock: clock
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installing, .installedAfterInstallerClosed])
        #expect(clock.sleepCount == 6, "four polls with Installer.app open, then three closed polls")
    }

    @Test func anInstallerThatFinishedBeforeTheFirstPollStillEndsInstalled() async {
        let subject = installer(
            runner: PackageFakeRunner(receiptAfterChecks: 0),
            locator: PackageFakeLocator(appearsAfterChecks: 1),
            monitor: PackageFakeMonitor(runningChecks: 0), timeout: .seconds(5)
        )

        let states = await collectStates(subject.install(package: packageFixtureURL, app: packageCatalogApp()))

        #expect(states == [.waitingForUser, .installing, .installedAfterInstallerClosed])
    }

    // MARK: What the installer asks for

    @Test func theInstallerAsksForTheCatalogBundleIDAndTeamID() async {
        let verifier = PackageFakeVerifier(result: .valid(teamID("EQHXZ8M8AV")))
        let locator = PackageFakeLocator(appearsAfterChecks: 2)
        let app = packageCatalogApp()
        let subject = installer(
            verifier: verifier, runner: PackageFakeRunner(receiptAfterChecks: 1), locator: locator
        )

        _ = await collectStates(subject.install(package: packageFixtureURL, app: app))

        #expect(verifier.expectedTeamIDs == [app.teamID])
        #expect(locator.checkCount >= 2, "the already-installed check and at least one poll")
        #expect(locator.askedBundleIDs.allSatisfy { $0 == app.bundleID })
        #expect(locator.askedBundleIDs.count == locator.checkCount)
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
        #expect(await runner.toolNames == ["pkgutil", "open"])
    }

    @Test func alreadyInstalledAppEmitsFailedAndNeverOpensThePackage() async {
        let runner = PackageFakeRunner()
        let locator = PackageFakeLocator(appearsAfterChecks: 0)
        let app = packageCatalogApp()
        let subject = installer(runner: runner, locator: locator)

        let states = await collectStates(subject.install(package: packageFixtureURL, app: app))

        #expect(states == [.failed(.alreadyInstalled)])
        #expect(await runner.calls.isEmpty)
        #expect(locator.askedBundleIDs == [app.bundleID])
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
