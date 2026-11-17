import Foundation
import Testing
@testable import SettleInCore

/// When the app is not removed, no support path is removed either. Each path left alone is marked as refused
/// with a reason. These tests extend `UninstallerTests`, so `--filter UninstallerTests` runs them.
extension UninstallerTests {
    private func plainEntry(paths: [String]) throws -> CatalogApp {
        try UninstallTestApp.catalogApp(paths: paths)
    }

    @Test func anAppTheGuardRefusesLeavesEverySupportPathInPlace() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeSymlink(
            at: sandbox.applications.appendingPathComponent(UninstallTestApp.name), to: sandbox.outside
        )
        let support = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(support)
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let quits = CallCounter()
        let catalogApp = try plainEntry(paths: ["~/Library/Application Support/Doomed"])

        let report = try await Uninstaller.testing(sandbox, trash: trash, quitCounter: quits).uninstall(app: catalogApp)

        #expect(report.items.count == 2)
        for item in report.items {
            guard case .refused(let reason) = item.outcome else {
                Issue.record("\(item.path) was not refused: \(item.outcome)")
                continue
            }
            #expect(!reason.isEmpty)
        }
        #expect(sandbox.exists(support))
        #expect(trash.trashedPaths.isEmpty)
        #expect(quits.timesCalled == 0)
    }

    @Test func anAppThatCannotBeRemovedLeavesEverySupportPathInPlace() async throws {
        let sandbox = try UninstallSandbox.make()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sandbox.applications.path)
            sandbox.cleanUp()
        }
        let app = try sandbox.makeApp(named: UninstallTestApp.name, bundleID: bundleID)
        let support = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(support)
        // The Trash fails, and the applications folder is read-only, so the direct delete fails too.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sandbox.applications.path)
        let trash = FakeTrash(folder: sandbox.trashFolder, fails: true)
        let catalogApp = try plainEntry(paths: ["~/Library/Application Support/Doomed"])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        #expect(sandbox.exists(app))
        #expect(sandbox.exists(support))
        #expect(trash.trashedPaths.count == 1, "the Trash was tried for the app only")
        guard case .refused(let appReason) = report.outcomes[0],
              case .refused(let supportReason) = report.outcomes[1]
        else {
            Issue.record("expected two refusals, got \(report.outcomes)")
            return
        }
        #expect(appReason.contains("both failed"))
        #expect(supportReason.contains("did not remove the app"))
    }

    @Test func anAppThatIsAlreadyGoneDoesNotBlockTheSupportPaths() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let support = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(support)
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let catalogApp = try plainEntry(paths: ["~/Library/Application Support/Doomed"])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        #expect(report.outcomes == [.skipped, .trashed])
        #expect(!sandbox.exists(support))
    }

    @Test func aPackageEntryWhoseAppIsRefusedByTheGuardRemovesNoSupportPath() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let support = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(support)
        guard let identifier = PackageIdentifier("com.example.Doomed.pkg") else { fatalError("bad literal") }
        // `/Applications/Doomed.app` is outside the temp roots, so the guard refuses it.
        let catalogApp = try UninstallTestApp.catalogApp(
            install: .pkg(identifier: identifier),
            paths: ["/Applications/Doomed.app", "~/Library/Application Support/Doomed"]
        )
        let trash = FakeTrash(folder: sandbox.trashFolder)

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        #expect(report.items.map(\.path) == ["/Applications/Doomed.app", "~/Library/Application Support/Doomed"])
        #expect(report.outcomes.allSatisfy { if case .refused = $0 { true } else { false } })
        #expect(sandbox.exists(support))
        #expect(trash.trashedPaths.isEmpty)
    }
}
