import Foundation
import Testing
@testable import SettleInCore

/// A small seeded generator, so a failing run can repeat. No package is involved.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Builds hostile path text from pieces. The pieces name only things inside the temp tree.
struct HostilePathGenerator {
    private let prefixes: [String]
    private static let segments = [
        "Foo", "Foo.app", "FOO", "foo", "Foo ", "nest", "Application Support", "Caches",
        "..", ".", "", "...", "~", "*", "%2e%2e", "$HOME",
        "Café", "Cafe\u{301}", "日本語", "🙂", "a\nb", "nul\0byte",
        "out", "inroot", "dangling", "out/new", "inroot/nest",
        "Keychains", "Utilities", "Foo.APP", "Bar.app", "Mobile Documents"
    ]
    private static let separators = ["/", "/", "/", "//", "///", "/./"]
    private static let endings = ["", "", "/", "//", "/."]

    init(sandbox: UninstallSandbox) {
        let apps = sandbox.applications.path
        let lowerApps = sandbox.root.path + "/applications"
        prefixes = [
            "~/Library", "~/Library", "~/Library/Application Support", "~/.config", "~/.config",
            "~/Library/Caches", "~/Library/Logs", "~/Library/Preferences", "~/.config/Foo", "~/.config/nest",
            apps, apps, apps, apps + "/Foo.app", apps + "-evil", sandbox.root.path + "/Applications2", lowerApps,
            apps.uppercased(),
            sandbox.home.path + "/Library", sandbox.home.path + "/.config", sandbox.home.path + "/Library-evil",
            sandbox.home.path + "/Library/Application Support", sandbox.home.path + "/Documents",
            "~/library", "~/.CONFIG", "~/Library-evil", "~/Documents", "~", "~root", "~/", "/", "", "//" + apps,
            "/Applications", "/Applications-evil", "/applications", sandbox.outside.path, sandbox.root.path
        ]
    }

    func next(using rng: inout SplitMix64) -> String {
        var text = prefixes[Int.random(in: 0..<prefixes.count, using: &rng)]
        for _ in 0..<Int.random(in: 0...6, using: &rng) {
            text += Self.separators[Int.random(in: 0..<Self.separators.count, using: &rng)]
            text += Self.segments[Int.random(in: 0..<Self.segments.count, using: &rng)]
        }
        return text + Self.endings[Int.random(in: 0..<Self.endings.count, using: &rng)]
    }
}

@Suite(.serialized)
struct PathGuardPropertyTests {
    /// Set `SETTLEIN_PATH_SEED` to repeat a failing run.
    static let seed: UInt64 = ProcessInfo.processInfo.environment["SETTLEIN_PATH_SEED"].flatMap { UInt64($0) }
        ?? 0x5E77_1E1D

    static let pathCount = 6_000

    /// Makes real folders, files, and links in each root so generated paths reach existing items, links that
    /// leave the roots, links that stay inside, and links that point at nothing.
    private func buildTree(in sandbox: UninstallSandbox) throws {
        let library = sandbox.home.appendingPathComponent("Library")
        for base in [sandbox.applications, sandbox.support, sandbox.config, library] {
            try sandbox.makeFolder(base.appendingPathComponent("Foo"))
            try sandbox.makeFolder(base.appendingPathComponent("Foo.app"))
            try sandbox.makeFolder(base.appendingPathComponent("nest/nest"))
            try sandbox.makeSymlink(at: base.appendingPathComponent("out"), to: sandbox.outside)
            try sandbox.makeSymlink(at: base.appendingPathComponent("inroot"), to: base.appendingPathComponent("Foo"))
            let gone = sandbox.root.appendingPathComponent("gone")
            try sandbox.makeSymlink(at: base.appendingPathComponent("dangling"), to: gone)
        }
    }

    private func isInside(_ path: String, root: String) -> Bool {
        let components = PathResolutionTestHelper.components(path)
        let rootComponents = PathResolutionTestHelper.components(root)
        return components.count > rootComponents.count
            && Array(components.prefix(rootComponents.count)) == rootComponents
    }

    /// An independent statement of the shape rules, written out here and not read from `UninstallPathShape`.
    private func followsTheShapeRules(_ resolved: String, roots: [String]) -> Bool {
        let libraryFolders: Set<String> = [
            "Application Support", "Caches", "Preferences", "Logs", "Containers",
            "Saved Application State", "HTTPStorages", "WebKit", "Cookies"
        ]
        let components = PathResolutionTestHelper.components(resolved)
        func relative(to root: String) -> [String] {
            Array(components.dropFirst(PathResolutionTestHelper.components(root).count))
        }
        func isApp(_ name: String) -> Bool { name.lowercased().hasSuffix(".app") }
        if isInside(resolved, root: roots[0]) {
            let below = relative(to: roots[0])
            return below.count == 1 && isApp(below[0]) && below[0].count > 4
        }
        if isInside(resolved, root: roots[1]) {
            let below = relative(to: roots[1])
            return below.count >= 2 && libraryFolders.contains(below[0])
        }
        if isInside(resolved, root: roots[2]) {
            let below = relative(to: roots[2])
            return below.count >= 1
        }
        return false
    }

    @Test func everyApprovedPathResolvesInsideARoot() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        try buildTree(in: sandbox)
        let guardian = PathGuard(roots: sandbox.roots)
        let generator = HostilePathGenerator(sandbox: sandbox)
        var rng = SplitMix64(seed: Self.seed)
        let rootPaths = [sandbox.applications, sandbox.home.appendingPathComponent("Library"), sandbox.config]
            .map { realPath($0.path) }
        var approvedCount = 0
        var rejectedCount = 0

        for _ in 0..<Self.pathCount {
            let text = generator.next(using: &rng)
            let note = Comment(rawValue: "seed \(Self.seed), path \(text.debugDescription)")
            guard let approved = try? guardian.approve(text) else {
                rejectedCount += 1
                continue
            }
            approvedCount += 1
            let resolved = approved.url.path
            #expect(rootPaths.contains { isInside(resolved, root: $0) }, note)
            #expect(realPath(resolved) == resolved, note)
            #expect(!text.split(separator: "/", omittingEmptySubsequences: false).contains(".."), note)
            let direct = isInside(resolved, root: rootPaths[1]) && PathResolutionTestHelper.components(resolved).count
                == PathResolutionTestHelper.components(rootPaths[1]).count + 1
            #expect(!direct, note)
            #expect(followsTheShapeRules(resolved, roots: rootPaths), note)
        }

        #expect(approvedCount > 200, "seed \(Self.seed): only \(approvedCount) paths were approved")
        #expect(rejectedCount > 2_000, "seed \(Self.seed): only \(rejectedCount) paths were rejected")
        #expect(approvedCount + rejectedCount == Self.pathCount)
    }

    @Test func sameSeedGivesTheSamePaths() throws {
        let sandbox = try UninstallSandbox.make()
        defer { sandbox.cleanUp() }
        let generator = HostilePathGenerator(sandbox: sandbox)
        var first = SplitMix64(seed: Self.seed)
        var second = SplitMix64(seed: Self.seed)
        let one = (0..<50).map { _ in generator.next(using: &first) }
        let two = (0..<50).map { _ in generator.next(using: &second) }
        #expect(one == two)
    }
}

enum PathResolutionTestHelper {
    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
