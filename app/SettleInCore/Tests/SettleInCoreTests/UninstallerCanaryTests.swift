import Foundation
import Testing
@testable import SettleInCore

/// A canary file sits outside the fake home and the fake applications folder. Each test sends hostile
/// catalog paths and symlinks at it, and then checks that the canary survived.
///
/// These tests extend `UninstallerTests`, so `--filter UninstallerTests` runs them.
extension UninstallerTests {
    private func hostileTree(_ sandbox: UninstallSandbox) throws {
        let support = sandbox.support
        // A real folder that holds a link to the outside folder. Removing the folder must not follow the link.
        try sandbox.makeFolder(support.appendingPathComponent("Hostile"))
        try sandbox.makeSymlink(at: support.appendingPathComponent("Hostile/inner-link"), to: sandbox.outside)
        try sandbox.makeSymlink(at: support.appendingPathComponent("Hostile/file-link"), to: sandbox.canary)
        try sandbox.makeSymlink(at: support.appendingPathComponent("EscapeLink"), to: sandbox.outside)
        try sandbox.makeSymlink(at: support.appendingPathComponent("UsersLink"), to: URL(fileURLWithPath: "/Users"))
        try sandbox.makeFolder(sandbox.config.appendingPathComponent("tool"))
        try sandbox.makeSymlink(at: sandbox.config.appendingPathComponent("tool/canary-link"), to: sandbox.canary)
        try sandbox.makeSymlink(
            at: sandbox.home.appendingPathComponent("Library/Caches"),
            to: sandbox.home.appendingPathComponent("Documents")
        )
        try sandbox.makeFolder(sandbox.applications.appendingPathComponent("Other.app"))
    }

    private var hostilePaths: [String] { [
        "~/Library/Application Support/Hostile",
        "~/Library/Application Support/EscapeLink",
        "~/Library/Application Support/EscapeLink/canary.txt",
        "~/Library/Application Support/UsersLink",
        "~/Library/Caches/canary.txt",
        "~/Library/Caches/Documents/canary.txt",
        "~/.config/tool/canary-link",
        "/Applications/Other.app",
        "/Applications/Foo.app",
        "~/Library/Application Support/Missing/Deeper"
    ] }

    private func assertSurvived(_ sandbox: UninstallSandbox) {
        #expect(sandbox.canariesIntact)
        #expect(sandbox.exists(sandbox.outside))
        #expect(sandbox.exists(sandbox.applications.appendingPathComponent("Other.app")))
        #expect(sandbox.exists(sandbox.support.appendingPathComponent("EscapeLink")))
        #expect(sandbox.exists(sandbox.support.appendingPathComponent("UsersLink")))
        #expect(sandbox.exists(sandbox.config.appendingPathComponent("tool/canary-link")))
        #expect(FileManager.default.fileExists(atPath: "/Users"))
    }

    @Test func hostileCatalogPathsLeaveTheCanaryAlone() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try hostileTree(sandbox)
        try sandbox.makeApp(named: UninstallTestApp.name, bundleID: UninstallTestApp.bundleID)
        let catalogApp = try UninstallTestApp.catalogApp(paths: hostilePaths)

        let report = try await Uninstaller.testing(sandbox, trash: FakeTrash(folder: sandbox.trashFolder))
            .uninstall(app: catalogApp)

        assertSurvived(sandbox)
        #expect(report.items.count == hostilePaths.count + 1)
        #expect(report.outcomes[0] == .trashed)
        #expect(report.outcomes[1] == .trashed, "the real Hostile folder goes to the Trash with its links unfollowed")
        let refusedIndexes = [2, 3, 4, 5, 6, 7, 8, 9]
        for index in refusedIndexes {
            guard case .refused = report.outcomes[index] else {
                Issue.record("path \(report.items[index].path) was not refused: \(report.outcomes[index])")
                continue
            }
        }
        #expect(report.outcomes[10] == .skipped)
    }

    @Test func hostileCatalogPathsLeaveTheCanaryAloneWhenTheTrashFails() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try hostileTree(sandbox)
        try sandbox.makeApp(named: UninstallTestApp.name, bundleID: UninstallTestApp.bundleID)
        let catalogApp = try UninstallTestApp.catalogApp(paths: hostilePaths)

        let report = try await Uninstaller.testing(sandbox, trash: FakeTrash(folder: sandbox.trashFolder, fails: true))
            .uninstall(app: catalogApp)

        assertSurvived(sandbox)
        #expect(report.outcomes[0] == .deleted)
        #expect(report.outcomes[1] == .deleted, "a delete removes the links, not what they point to")
        #expect(!sandbox.exists(sandbox.support.appendingPathComponent("Hostile")))
    }

    @Test func aSymlinkInApplicationSupportThatPointsToUsersIsRefused() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let users = URL(fileURLWithPath: "/Users")
        try sandbox.makeSymlink(at: sandbox.support.appendingPathComponent("Shortcut"), to: users)
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let catalogApp = try UninstallTestApp.catalogApp(paths: ["~/Library/Application Support/Shortcut"])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        #expect(report.outcomes[0] == .skipped)
        guard case .refused(let reason) = report.outcomes[1] else {
            Issue.record("the link was not refused: \(report.outcomes)")
            return
        }
        #expect(reason.contains("outside"))
        #expect(trash.trashedPaths.isEmpty)
        #expect(sandbox.exists(sandbox.support.appendingPathComponent("Shortcut")))
        #expect(FileManager.default.fileExists(atPath: "/Users"))
    }

    @Test func theAppPathItselfCannotBeASymlinkToTheCanary() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let appLink = sandbox.applications.appendingPathComponent(UninstallTestApp.name)
        try sandbox.makeSymlink(at: appLink, to: sandbox.outside)
        let trash = FakeTrash(folder: sandbox.trashFolder)

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: UninstallTestApp.catalogApp())

        guard case .refused = report.outcomes[0] else {
            Issue.record("the linked app was not refused: \(report.outcomes)")
            return
        }
        #expect(trash.trashedPaths.isEmpty)
        #expect(sandbox.canariesIntact)
    }
}
