import Foundation
import Testing
@testable import SettleInCore

/// A listed path inside a real bundle must belong to the catalog entry's app. A real bundle is a folder that
/// ends in `.app` and holds `Contents/Info.plist`. A `.app` folder without a plist is a plain folder. The listed
/// bundles here sit under the fake home, because the fake applications folder has no catalog text that names it.
extension UninstallerTests {
    private static let listedApp = "~/Library/Application Support/Vendor/Listed.app"

    private func packageEntry(paths: [String]) throws -> CatalogApp {
        guard let identifier = PackageIdentifier("com.example.Doomed.pkg") else { fatalError("bad literal") }
        return try UninstallTestApp.catalogApp(install: .pkg(identifier: identifier), paths: paths)
    }

    private func listedBundle(in sandbox: UninstallSandbox) -> URL {
        sandbox.support.appendingPathComponent("Vendor/Listed.app", isDirectory: true)
    }

    @Test func aRealBundleOfAnotherAppUnderApplicationSupportIsRefusedAndTheOtherPathsGoOn() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let listed = try sandbox.makeBundle(at: listedBundle(in: sandbox), bundleID: "com.example.SomethingElse")
        let support = sandbox.support.appendingPathComponent("Doomed")
        try sandbox.makeFolder(support)
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let catalogApp = try packageEntry(paths: [Self.listedApp, "~/Library/Application Support/Doomed"])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        guard case .refused(let reason) = report.outcomes[0] else {
            Issue.record("the listed app was not refused: \(report.outcomes)")
            return
        }
        #expect(reason.contains("different app"))
        #expect(sandbox.exists(listed))
        #expect(trash.trashedPaths.count == 1, "only the plain folder reaches the Trash")
        #expect(report.outcomes[1] == .trashed)
        #expect(sandbox.canariesIntact)
    }

    @Test func aPathInsideARealBundleOfAnotherAppIsRefused() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let bundle = try sandbox.makeBundle(at: listedBundle(in: sandbox), bundleID: "com.apple.Safari")
        let inner = bundle.appendingPathComponent("Contents/Resources/data", isDirectory: true)
        try sandbox.makeFolder(inner)
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let inside = "~/Library/Application Support/Vendor/Listed.app/Contents/Resources/data"
        let catalogApp = try packageEntry(paths: [inside])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        guard case .refused(let reason) = report.outcomes[0] else {
            Issue.record("the inner path was not refused: \(report.outcomes)")
            return
        }
        #expect(reason.contains("different app"))
        #expect(sandbox.exists(inner))
        #expect(trash.trashedPaths.isEmpty)
    }

    @Test func aFolderNamedLikeAnAppWithoutAPlistIsAPlainFolderAndIsRemoved() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let container = sandbox.home.appendingPathComponent("Library/Containers/com.vendor.app", isDirectory: true)
        let caches = container.appendingPathComponent("Data/Library/Caches", isDirectory: true)
        try sandbox.makeFolder(caches)
        let plain = sandbox.home.appendingPathComponent("Library/Caches/com.vendor.app", isDirectory: true)
        try sandbox.makeFolder(plain)
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let catalogApp = try packageEntry(paths: [
            "~/Library/Containers/com.vendor.app/Data/Library/Caches", "~/Library/Caches/com.vendor.app"
        ])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        #expect(report.outcomes == [.trashed, .trashed])
        #expect(!sandbox.exists(caches) && !sandbox.exists(plain))
        #expect(sandbox.canariesIntact)
    }

    @Test func aPackageEntryWithAListedAppOfAnotherBundleIsNotDeletedWhenTheTrashFails() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let listed = try sandbox.makeBundle(at: listedBundle(in: sandbox), bundleID: "com.apple.Safari")
        let trash = FakeTrash(folder: sandbox.trashFolder, fails: true)

        let report = try await Uninstaller.testing(sandbox, trash: trash)
            .uninstall(app: packageEntry(paths: [Self.listedApp]))

        guard case .refused = report.outcomes[0] else {
            Issue.record("the listed app was not refused: \(report.outcomes)")
            return
        }
        #expect(sandbox.exists(listed))
        #expect(trash.trashedPaths.isEmpty)
        #expect(sandbox.canariesIntact)
    }

    @Test func aPackageEntryWithAListedAppOfTheRightBundleRemovesIt() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let listed = try sandbox.makeBundle(at: listedBundle(in: sandbox), bundleID: bundleID)

        let report = try await Uninstaller.testing(sandbox, trash: FakeTrash(folder: sandbox.trashFolder))
            .uninstall(app: packageEntry(paths: [Self.listedApp]))

        #expect(report.outcomes == [.trashed])
        #expect(!sandbox.exists(listed))
    }

    @Test func aListedAppFolderWithoutAPlistIsAPlainFolderAndIsRemoved() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let listed = listedBundle(in: sandbox)
        try sandbox.makeFolder(listed)

        let report = try await Uninstaller.testing(sandbox, trash: FakeTrash(folder: sandbox.trashFolder))
            .uninstall(app: packageEntry(paths: [Self.listedApp]))

        #expect(report.outcomes == [.trashed])
        #expect(!sandbox.exists(listed))
    }

    @Test func aZipEntryThatListsAnUnrelatedAppIsRefusedAndItsOwnAppIsRemoved() async throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let own = try sandbox.makeApp(named: UninstallTestApp.name, bundleID: bundleID)
        let unrelated = try sandbox.makeBundle(at: listedBundle(in: sandbox), bundleID: "com.apple.Safari")
        let trash = FakeTrash(folder: sandbox.trashFolder)
        let catalogApp = try UninstallTestApp.catalogApp(paths: [Self.listedApp])

        let report = try await Uninstaller.testing(sandbox, trash: trash).uninstall(app: catalogApp)

        #expect(report.outcomes[0] == .trashed)
        guard case .refused = report.outcomes[1] else {
            Issue.record("the unrelated app was not refused: \(report.outcomes)")
            return
        }
        #expect(!sandbox.exists(own))
        #expect(sandbox.exists(unrelated))
        #expect(trash.trashedPaths.count == 1)
        #expect(sandbox.canariesIntact)
    }
}
