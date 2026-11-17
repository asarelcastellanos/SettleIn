import Foundation
import Testing
@testable import SettleInCore

/// Every test builds its own temp tree. No test reads the real `/Applications` or the real home folder.
@Suite(.serialized)
struct PathGuardTests {
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

    // MARK: Approval

    @Test func approvesPathsInsideEachRoot() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        for text in [
            sandbox.applications.path + "/Foo.app",
            "~/Library/Application Support/Foo",
            "~/Library/Caches/com.example.Foo/deep/file",
            "~/.config/foo/settings.toml",
            sandbox.home.path + "/Library/Preferences/com.example.Foo.plist"
        ] {
            #expect(throws: Never.self) { try approved(text, in: sandbox) }
        }
    }

    @Test func approvedPathIsTheResolvedPathAndKeepsTheOriginalText() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeFolder(sandbox.support.appendingPathComponent("Foo"))
        let text = "~/Library/Application Support/Foo"
        let path = try approved(text, in: sandbox)
        #expect(path.text == text)
        #expect(path.url.path == realPath(sandbox.support.path) + "/Foo")
    }

    @Test func tempFolderUnderVarResolvesToPrivateVar() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let path = try approved(sandbox.applications.path + "/Foo.app", in: sandbox)
        #expect(path.url.path == realPath(sandbox.applications.path) + "/Foo.app")
        if sandbox.root.path.hasPrefix("/var/") { #expect(path.url.path.hasPrefix("/private/var/")) }
    }

    @Test func approvesAPathWhoseLastComponentDoesNotExist() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let path = try approved("~/Library/Application Support/Missing/Deeper", in: sandbox)
        #expect(path.url.path == realPath(sandbox.support.path) + "/Missing/Deeper")
    }

    @Test func standardizesRepeatedAndTrailingSlashesAndDots() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let expected = try approved("~/Library/Application Support/Foo", in: sandbox).url
        for text in [
            "~//Library///Application Support//Foo/",
            "~/Library/./Application Support/./Foo//",
            sandbox.home.path + "//Library/Application Support/Foo/"
        ] {
            #expect(try approved(text, in: sandbox).url == expected)
        }
    }

    @Test func tildeInTheMiddleIsAnOrdinaryName() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let path = try approved("~/Library/Application Support/~/x", in: sandbox)
        #expect(path.url.path.hasSuffix("/Application Support/~/x"))
        #expect(rejection("~root/Library/Application Support/x", in: sandbox) == .notAbsolute)
        #expect(rejection("Library/Application Support/x", in: sandbox) == .notAbsolute)
    }

    @Test func acceptsUnicodeNames() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        for name in ["Café", "Cafe\u{301}", "日本語", "🙂"] {
            #expect(throws: Never.self) { try approved("~/Library/Application Support/\(name)", in: sandbox) }
        }
    }

    @Test func approvesAnUninstallPathFromTheCatalog() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let path = try UninstallPath("~/.config/foo/settings.toml")
        let result = try PathGuard(roots: sandbox.roots).approve(path)
        #expect(result.text == "~/.config/foo/settings.toml")
    }

    @Test func approvesWhenARootOrTheHomeIsItselfASymlink() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let dotfiles = sandbox.root.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: sandbox.config)
        try sandbox.makeSymlink(at: sandbox.config, to: dotfiles)
        let homeLink = sandbox.root.appendingPathComponent("homelink")
        try sandbox.makeSymlink(at: homeLink, to: sandbox.home)

        let viaLink = PathGuard(roots: AllowedRoots(home: homeLink, applications: sandbox.applications))
        #expect(throws: Never.self) { try viaLink.approve("~/.config/foo/settings.toml") }
        #expect(throws: Never.self) { try viaLink.approve("~/Library/Application Support/Foo") }
    }

    // MARK: Rejection

    @Test func refusesASiblingFolderThatSharesAPrefixWithARoot() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeFolder(sandbox.root.appendingPathComponent("Applications-evil/Foo.app"))
        try sandbox.makeFolder(sandbox.home.appendingPathComponent("Library-evil/Foo"))
        #expect(rejection(sandbox.root.path + "/Applications-evil/Foo.app", in: sandbox) == .outsideRoots)
        #expect(rejection(sandbox.home.path + "/Library-evil/Foo", in: sandbox) == .outsideRoots)
        #expect(rejection("/Applications-evil/Foo.app", in: sandbox) == .outsideRoots)
    }

    @Test func refusesAPathOutsideEveryRoot() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        for text in ["/Applications/Foo.app", "/etc/hosts", "~", "~/Documents/x", sandbox.outside.path + "/x", "/"] {
            #expect(rejection(text, in: sandbox) == .outsideRoots, "\(text)")
        }
    }

    @Test func refusesTheRootsThemselves() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        for text in [sandbox.applications.path, sandbox.applications.path + "/", "~/Library", "~/Library/", "~/.config",
                     "~/.config//", sandbox.home.path + "/.config"] {
            #expect(rejection(text, in: sandbox) == .isRoot, "\(text)")
        }
    }

    @Test func refusesADirectChildOfLibrary() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        for text in ["~/Library/Caches", "~/Library/Application Support/", "~/Library/Foo.plist"] {
            #expect(rejection(text, in: sandbox) == .directChildOfLibrary, "\(text)")
        }
    }

    @Test func refusesParentTraversalWithoutStandardizingItAway() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        for text in [
            "~/Library/Application Support/../Preferences/x",
            "~/Library/Application Support/Foo/..",
            sandbox.applications.path + "/../outside/x",
            "~/.config/foo/../../Documents/canary.txt"
        ] {
            #expect(rejection(text, in: sandbox) == .parentTraversal, "\(text)")
        }
    }

    @Test func refusesAPathWhoseCaseDiffersFromARoot() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let lowered = sandbox.root.path + "/applications/Foo.app"
        #expect(rejection(lowered, in: sandbox) == .caseDiffersFromRoot)
        #expect(rejection("~/library/Application Support/Foo", in: sandbox) == .caseDiffersFromRoot)
        #expect(rejection("~/.CONFIG/foo", in: sandbox) == .caseDiffersFromRoot)
        #expect(rejection("/applications/Foo", in: sandbox) == .outsideRoots)
    }

    @Test func refusesMalformedText() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        #expect(rejection("", in: sandbox) == .malformed)
        #expect(rejection("~/.config/foo\0/../../x", in: sandbox) == .malformed)
        #expect(rejection("~/.config/foo\nbar", in: sandbox) == .malformed)
        #expect(rejection("~/.config/foo\u{7F}", in: sandbox) == .malformed)
    }

    // MARK: Symbolic links

    @Test func refusesASymlinkInsideApplicationSupportThatPointsToUsers() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let users = URL(fileURLWithPath: "/Users")
        try sandbox.makeSymlink(at: sandbox.support.appendingPathComponent("Shortcut"), to: users)
        #expect(rejection("~/Library/Application Support/Shortcut", in: sandbox) == .resolvesOutsideRoots)
        #expect(rejection("~/Library/Application Support/Shortcut/missing-settlein-test", in: sandbox)
            == .resolvesOutsideRoots)
    }

    @Test func refusesSymlinksThatLeaveTheRoots() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeSymlink(at: sandbox.support.appendingPathComponent("Out"), to: sandbox.outside)
        try sandbox.makeFolder(sandbox.config.appendingPathComponent("tool"))
        try sandbox.makeSymlink(at: sandbox.config.appendingPathComponent("tool/file"), to: sandbox.canary)
        try sandbox.makeSymlink(at: sandbox.applications.appendingPathComponent("Evil.app"), to: sandbox.outside)
        for text in [
            "~/Library/Application Support/Out",
            "~/Library/Application Support/Out/canary.txt",
            "~/Library/Application Support/Out/new-file",
            "~/.config/tool/file",
            sandbox.applications.path + "/Evil.app"
        ] {
            #expect(rejection(text, in: sandbox) == .resolvesOutsideRoots, "\(text)")
        }
    }

    @Test func refusesASymlinkThatStaysInsideTheRoots() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeFolder(sandbox.support.appendingPathComponent("Real"))
        try sandbox.makeSymlink(
            at: sandbox.support.appendingPathComponent("Alias"), to: sandbox.support.appendingPathComponent("Real")
        )
        #expect(rejection("~/Library/Application Support/Alias", in: sandbox) == .redirectedBySymlink)
        #expect(rejection("~/Library/Application Support/Alias/data.txt", in: sandbox) == .redirectedBySymlink)
    }

    @Test func refusesASymlinkThatLeadsToAnotherRoot() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeFolder(sandbox.config.appendingPathComponent("tool"))
        try sandbox.makeSymlink(
            at: sandbox.applications.appendingPathComponent("Tool.app"),
            to: sandbox.config.appendingPathComponent("tool")
        )
        #expect(rejection(sandbox.applications.path + "/Tool.app", in: sandbox) == .resolvesOutsideRoots)
    }

    @Test func refusesASymlinkThatPointsAtNothing() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeSymlink(
            at: sandbox.support.appendingPathComponent("Dangling"), to: sandbox.outside.appendingPathComponent("gone")
        )
        #expect(rejection("~/Library/Application Support/Dangling", in: sandbox) == .unresolvable)
        #expect(rejection("~/Library/Application Support/Dangling/x", in: sandbox) == .unresolvable)
    }

    @Test func approvalDoesNotChangeTheTree() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try sandbox.makeFolder(sandbox.support.appendingPathComponent("Foo"))
        let before = try FileManager.default.subpathsOfDirectory(atPath: sandbox.root.path).sorted()
        _ = try? approved("~/Library/Application Support/Foo", in: sandbox)
        _ = try? approved("~/Library/Application Support/Missing", in: sandbox)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: sandbox.root.path).sorted() == before)
    }
}

/// Resolves symbolic links with `realpath`. The tests use it to compute what the guard should return.
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
