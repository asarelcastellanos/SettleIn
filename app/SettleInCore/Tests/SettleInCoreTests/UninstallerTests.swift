import Foundation
import Testing
@testable import SettleInCore

/// Every test works inside a temp tree with a fake home and a fake applications folder. The Trash is a fake
/// that moves items into the tree, so no test touches the real Trash either.
@Suite(.serialized)
struct UninstallerTests {
    let bundleID = UninstallTestApp.bundleID

    // MARK: Removal

    @Test func trashesTheAppAndEachListedPathInOrder() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let app = try sandbox.makeApp(named: UninstallTestApp.name, bundleID: bundleID)
        let support = sandbox.support.appendingPathComponent("Doomed")
        let cache = sandbox.home.appendingPathComponent("Library/Caches/com.example.Doomed")
        let config = sandbox.config.appendingPathComponent("doomed")
        for folder in [support, cache, config] { try sandbox.makeFolder(folder) }
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let catalogApp = try UninstallTestApp.catalogApp(paths: [
            "~/Library/Application Support/Doomed", "~/Library/Caches/com.example.Doomed", "~/.config/doomed"
        ])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        #expect(report.outcomes == [.trashed, .trashed, .trashed, .trashed])
        #expect(report.items.map(\.path) == [app.path, "~/Library/Application Support/Doomed",
                                             "~/Library/Caches/com.example.Doomed", "~/.config/doomed"])
        #expect([app, support, cache, config].allSatisfy { !sandbox.exists($0) })
        #expect(trash.trashedPaths.count == 4)
        #expect(sandbox.canariesIntact)
    }

    @Test func aPathThatDoesNotExistIsSkipped() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let catalogApp = try UninstallTestApp.catalogApp(paths: ["~/Library/Application Support/Missing"])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        #expect(report.outcomes == [.skipped, .skipped])
        #expect(trash.trashedPaths.isEmpty)
    }

    @Test func aPackageEntryHasNoAppAndRemovesOnlyItsListedPaths() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let support = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(support)
        guard let identifier = PackageIdentifier("com.example.Doomed.pkg") else { fatalError("bad literal") }
        let catalogApp = try UninstallTestApp.catalogApp(
            install: .pkg(identifier: identifier), paths: ["~/Library/Application Support/Doomed"]
        )

        let report = try await Uninstaller.testing(sandbox, trash: FakeTrash(folder: sandbox.trashFolder))
            .uninstall(app: catalogApp)

        #expect(report.outcomes == [.trashed])
        #expect(!sandbox.exists(support))
    }

    // MARK: Wrong app

    @Test func aDifferentAppAtTheAppPathRemovesNothing() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let other = try sandbox.makeApp(named: UninstallTestApp.name, bundleID: "com.example.SomethingElse")
        let support = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(support)
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let quits = CallCounter()
        let catalogApp = try UninstallTestApp.catalogApp(paths: ["~/Library/Application Support/Doomed"])

        let report = try await Uninstaller.testing(sandbox, trash: trash, quitCounter: quits).uninstall(app: catalogApp)

        #expect(sandbox.exists(other))
        #expect(sandbox.exists(support))
        #expect(trash.trashedPaths.isEmpty)
        #expect(quits.timesCalled == 0)
        #expect(report.items.count == 2)
        guard case .refused(let reason) = report.items[0].outcome else {
            Issue.record("the app was not refused")
            return
        }
        #expect(reason.contains("different app"))
        #expect(report.items[1].outcome != .trashed)
    }

    @Test func anAppWithoutAReadableBundleIdentifierCountsAsADifferentApp() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let bare = sandbox.applications.appendingPathComponent(UninstallTestApp.name, isDirectory: true)
        try sandbox.makeFolder(bare)
        let trash = FakeTrash(folder: sandbox.trashFolder)

        let report = try await Uninstaller.testing(sandbox, trash: trash)
            .uninstall(app: UninstallTestApp.catalogApp())

        #expect(sandbox.exists(bare))
        #expect(trash.trashedPaths.isEmpty)
        #expect(report.outcomes.count == 1)
        #expect(report.outcomes[0] != .trashed)
    }

    // MARK: Quit

    @Test func aRunningAppAndARefusedQuitRemovesNothing() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let app = try sandbox.makeApp(named: UninstallTestApp.name, bundleID: bundleID)
        let support = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(support)
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let running = FakeRunningApps(running: true)
        let quits = CallCounter()
        let uninstaller = Uninstaller.testing(
            sandbox, trash: trash, runningApps: running, quitAnswer: false, quitCounter: quits
        )
        let catalogApp = try UninstallTestApp.catalogApp(paths: ["~/Library/Application Support/Doomed"])

        await #expect(throws: UninstallError.appStillRunning) { try await uninstaller.uninstall(app: catalogApp) }

        #expect(quits.timesCalled == 1)
        #expect(running.terminateTimeouts.isEmpty)
        #expect(sandbox.exists(app) && sandbox.exists(support))
        #expect(trash.trashedPaths.isEmpty)
    }

    @Test func aConfirmedQuitTerminatesTheAppAndThenRemovesIt() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let app = try sandbox.makeApp(named: UninstallTestApp.name, bundleID: bundleID)
        let running = FakeRunningApps(running: true)
        let uninstaller = Uninstaller.testing(
            sandbox, trash: FakeTrash(folder: sandbox.trashFolder), runningApps: running
        )

        let report = try await uninstaller.uninstall(app: UninstallTestApp.catalogApp())

        #expect(running.terminateTimeouts == [.seconds(10)])
        #expect(report.outcomes == [.trashed])
        #expect(!sandbox.exists(app))
    }

    @Test func anAppThatDoesNotQuitRemovesNothing() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let app = try sandbox.makeApp(named: UninstallTestApp.name, bundleID: bundleID)
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let uninstaller = Uninstaller.testing(
            sandbox, trash: trash, runningApps: FakeRunningApps(running: true, quitSucceeds: false)
        )
        let catalogApp = try UninstallTestApp.catalogApp()

        await #expect(throws: UninstallError.appStillRunning) { try await uninstaller.uninstall(app: catalogApp) }

        #expect(sandbox.exists(app))
        #expect(trash.trashedPaths.isEmpty)
    }

    @Test func aStoppedAppIsNotAskedToQuit() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeApp(named: UninstallTestApp.name, bundleID: bundleID)
        let quits = CallCounter()
        let running = FakeRunningApps(running: false)
        let uninstaller = Uninstaller.testing(
            sandbox, trash: FakeTrash(folder: sandbox.trashFolder), runningApps: running, quitCounter: quits
        )

        _ = try await uninstaller.uninstall(app: UninstallTestApp.catalogApp())

        #expect(quits.timesCalled == 0)
        #expect(running.terminateTimeouts.isEmpty)
    }

    // MARK: Trash failure

    @Test func aFailedTrashFallsBackToDeleteForApprovedPathsOnly() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let app = try sandbox.makeApp(named: UninstallTestApp.name, bundleID: bundleID)
        let support = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(support)
        try sandbox.makeSymlink(at: sandbox.support.appendingPathComponent("Escape"), to: sandbox.outside)
        let trash = FakeTrash(folder: sandbox.trashFolder, fails: true)
        let catalogApp = try UninstallTestApp.catalogApp(paths: [
            "~/Library/Application Support/Doomed",
            "~/Library/Application Support/Escape",
            "~/Library/Application Support/Missing",
            "/Applications/Other.app"
        ])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        #expect(report.outcomes[0] == .deleted)
        #expect(report.outcomes[1] == .deleted)
        guard case .refused = report.outcomes[2], case .skipped = report.outcomes[3], case .refused = report.outcomes[4]
        else {
            Issue.record("unexpected outcomes \(report.outcomes)")
            return
        }
        #expect(!sandbox.exists(app) && !sandbox.exists(support))
        #expect(trash.trashedPaths.count == 2, "the Trash is tried only for approved paths")
        #expect(sandbox.exists(sandbox.support.appendingPathComponent("Escape")))
        #expect(sandbox.canariesIntact)
    }

    @Test func aPathSwappedForASymlinkAfterTheTrashFailsIsNotDeleted() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let victim = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(victim)
        let outside = sandbox.outside
        let trash = FakeTrash(folder: sandbox.trashFolder, fails: true) { url in
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("moved"))
            try? FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        }
        let catalogApp = try UninstallTestApp.catalogApp(paths: ["~/Library/Application Support/Doomed"])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        guard case .refused = report.outcomes[1] else {
            Issue.record("the swapped path was not refused: \(report.outcomes)")
            return
        }
        #expect(sandbox.canariesIntact)
        #expect(sandbox.exists(sandbox.outside))
    }
}
