import Foundation

/// Decides which catalog paths the uninstaller may touch. This is the one place that decides, and it
/// changes nothing on disk.
///
/// A path is approved when all of these hold.
/// - It starts with `/` or `~/`, and it has no `..` component after `~` is expanded.
/// - It is inside `/Applications`, `~/Library`, or `~/.config`, compared one component at a time and with
///   letter case respected. It is not a root itself, and it is not a direct child of `~/Library`.
/// - After every symbolic link in the path and its parent folders is resolved, the path is still inside the
///   same root and still has the same components below it. A symbolic link anywhere in the path refuses it.
public struct PathGuard: Sendable {
    public let roots: AllowedRoots

    public init(roots: AllowedRoots) {
        self.roots = roots
    }

    public func approve(_ path: UninstallPath) throws(PathRejection) -> ApprovedPath {
        try approve(path.rawValue)
    }

    public func approve(_ text: String) throws(PathRejection) -> ApprovedPath {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty, !scalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw .malformed
        }
        let expanded = try expandHome(in: text)
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains("..") else { throw .parentTraversal }
        let components = PathResolution.components(of: expanded)

        guard let lexical = place(components, in: lexicalRoots, caseSensitive: true) else {
            let ignoringCase = place(components, in: lexicalRoots, caseSensitive: false)
            throw ignoringCase == nil ? .outsideRoots : .caseDiffersFromRoot
        }
        try rejectRootAndLibraryChild(lexical)

        guard let resolvedComponents = PathResolution.resolve(components) else { throw .unresolvable }
        let resolvedRoots = try resolvedRootList()
        guard let resolved = place(resolvedComponents, in: resolvedRoots, caseSensitive: true),
              resolved.root == lexical.root
        else { throw .resolvesOutsideRoots }
        try rejectRootAndLibraryChild(resolved)
        guard resolved.relative == lexical.relative else { throw .redirectedBySymlink }

        return ApprovedPath(url: URL(fileURLWithPath: "/" + resolvedComponents.joined(separator: "/")), text: text)
    }

    // MARK: Roots

    private enum Root: CaseIterable {
        case applications, library, config
    }

    private struct Placement {
        let root: Root
        /// The components below the root.
        let relative: [String]
    }

    private func url(of root: Root) -> URL {
        switch root {
        case .applications: roots.applications
        case .library: roots.library
        case .config: roots.config
        }
    }

    private var lexicalRoots: [(Root, [String])] {
        Root.allCases.map { ($0, PathResolution.components(of: url(of: $0).path)) }
    }

    private func resolvedRootList() throws(PathRejection) -> [(Root, [String])] {
        var list: [(Root, [String])] = []
        for root in Root.allCases {
            guard let resolved = PathResolution.resolve(PathResolution.components(of: url(of: root).path)) else {
                throw .rootUnavailable
            }
            list.append((root, resolved))
        }
        return list
    }

    /// Finds the root that `components` starts with. A component matches only when it is equal, so
    /// `/Applications-evil` does not match `/Applications`.
    private func place(
        _ components: [String],
        in list: [(Root, [String])],
        caseSensitive: Bool
    ) -> Placement? {
        for (root, rootComponents) in list {
            guard components.count >= rootComponents.count else { continue }
            let head = Array(components.prefix(rootComponents.count))
            let matches = caseSensitive ? head == rootComponents
                : head.map { $0.lowercased() } == rootComponents.map { $0.lowercased() }
            if matches { return Placement(root: root, relative: Array(components.dropFirst(rootComponents.count))) }
        }
        return nil
    }

    private func rejectRootAndLibraryChild(_ placement: Placement) throws(PathRejection) {
        if placement.relative.isEmpty { throw .isRoot }
        if placement.root == .library, placement.relative.count == 1 { throw .directChildOfLibrary }
    }

    private func expandHome(in text: String) throws(PathRejection) -> String {
        if text == "~" { return roots.home.path }
        if text.hasPrefix("~/") { return roots.home.path + String(text.dropFirst()) }
        guard text.hasPrefix("/") else { throw .notAbsolute }
        return text
    }
}
