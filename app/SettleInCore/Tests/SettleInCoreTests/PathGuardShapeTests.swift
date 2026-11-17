import Foundation
import Testing
@testable import SettleInCore

/// The shape rules of `UninstallPathShape`, as `PathGuard` applies them. Every test builds its own temp tree.
@Suite(.serialized)
struct PathGuardShapeTests {
    private func rejection(_ text: String, in sandbox: UninstallSandbox) -> PathRejection? {
        do {
            _ = try PathGuard(roots: sandbox.roots).approve(text)
            return nil
        } catch {
            return error
        }
    }

    private func approved(_ text: String, in sandbox: UninstallSandbox) throws -> ApprovedPath {
        try PathGuard(roots: sandbox.roots).approve(text)
    }

    @Test func refusesAPathThatReachesIntoAnAppBundle() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let apps = sandbox.applications.path
        for text in [
            apps + "/Foo.app/Contents/MacOS/Foo",
            apps + "/Foo.APP/Contents",
            apps + "/Foo.app/Bar.app",
            "~/Library/Application Support/Foo.app/Contents/Info.plist",
            "~/Library/Caches/Vendor.App/x",
            "~/.config/tool.app/settings.toml"
        ] {
            #expect(rejection(text, in: sandbox) == .insideAppBundle, "\(text)")
        }
    }

    @Test func approvesABundleAsTheLastComponentUnderAnAllowedLibraryFolder() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        #expect(throws: Never.self) { try approved("~/Library/Application Support/Vendor/Listed.app", in: sandbox) }
    }

    @Test func approvesEachAllowedLibraryFolder() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let folders = [
            "Application Support", "Caches", "Preferences", "Logs", "Containers",
            "Saved Application State", "HTTPStorages", "WebKit", "Cookies"
        ]
        for folder in folders {
            #expect(throws: Never.self) { try approved("~/Library/\(folder)/com.example.Foo", in: sandbox) }
        }
    }

    @Test func refusesLibraryFoldersThatAreNotOnTheList() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        for text in [
            "~/Library/Keychains/login.keychain-db",
            "~/Library/Mobile Documents/com~apple~CloudDocs/Documents",
            "~/Library/Mail/V10/x",
            "~/Library/Messages/chat.db",
            "~/Library/Safari/History.db",
            "~/Library/Group Containers/group.com.example/x",
            "~/Library/LaunchAgents/com.example.plist",
            "~/Library/caches/x",
            "~/Library/APPLICATION SUPPORT/x"
        ] {
            #expect(rejection(text, in: sandbox) == .libraryFolderNotAllowed, "\(text)")
        }
    }

    @Test func approvesOnlyAnAppDirectlyUnderApplications() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let apps = sandbox.applications.path
        #expect(throws: Never.self) { try approved(apps + "/Foo.app", in: sandbox) }
        for text in [apps + "/Utilities/Foo.app", apps + "/Foo", apps + "/Foo/Bar", apps + "/.app"] {
            #expect(rejection(text, in: sandbox) == .notAnApplication, "\(text)")
        }
    }

    @Test func approvesTheAppsOwnFolderUnderConfigButNotConfigItself() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        #expect(throws: Never.self) { try approved("~/.config/foo", in: sandbox) }
        #expect(throws: Never.self) { try approved("~/.config/foo/bar", in: sandbox) }
        #expect(rejection("~/.config", in: sandbox) == .isRoot)
        #expect(rejection("~/.config/", in: sandbox) == .isRoot)
    }

    @Test func shapeRulesApplyBeforeAnythingIsReadFromDisk() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeFolder(sandbox.applications.appendingPathComponent("Foo.app/Contents"))
        let before = try FileManager.default.subpathsOfDirectory(atPath: sandbox.root.path).sorted()
        _ = rejection(sandbox.applications.path + "/Foo.app/Contents", in: sandbox)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: sandbox.root.path).sorted() == before)
    }
}
