import Foundation

/// A path that `PathGuard` refused, and the reason.
public enum PathRejection: Error, Equatable, Sendable, CustomStringConvertible {
    /// The text is empty or holds a control character, such as a NUL byte.
    case malformed
    /// The text does not start with `/` or with `~` and a slash.
    case notAbsolute
    /// A `..` component is left after `~` expansion.
    case parentTraversal
    /// The path is not under any allowed root.
    case outsideRoots
    /// The path matches a root only when case is ignored, such as `/applications/Foo`.
    case caseDiffersFromRoot
    case isRoot
    case directChildOfLibrary
    /// A component other than the last ends in `.app`, so the path reaches into a bundle.
    case insideAppBundle
    /// The first folder below `~/Library` is not one that SettleIn removes from.
    case libraryFolderNotAllowed
    /// A path under `/Applications` is not `/Applications/<Name>.app`.
    case notAnApplication
    /// The path is under a root as written, but its symlinks lead outside every root.
    case resolvesOutsideRoots
    /// A symlink sends the path to another place, even one inside a root. The uninstaller removes only
    /// the exact path the catalog names.
    case redirectedBySymlink
    /// A part of the path exists but cannot be resolved, such as a symlink that points at nothing.
    case unresolvable
    /// A root could not be resolved.
    case rootUnavailable

    public var description: String {
        switch self {
        case .malformed: "the path is empty or holds a control character"
        case .notAbsolute: "the path does not start with / or ~/"
        case .parentTraversal: "the path holds a .. component"
        case .outsideRoots: "the path is outside /Applications, ~/Library, and ~/.config"
        case .caseDiffersFromRoot: "the path differs from an allowed folder in letter case"
        case .isRoot: "the path is an allowed folder itself"
        case .directChildOfLibrary: "the path is a direct child of ~/Library"
        case .insideAppBundle: "the path goes inside an .app bundle"
        case .libraryFolderNotAllowed:
            "the first folder below ~/Library is not one of Application Support, Caches, Preferences, Logs, "
                + "Containers, Saved Application State, HTTPStorages, WebKit, or Cookies"
        case .notAnApplication: "a path in /Applications must be /Applications/<Name>.app"
        case .resolvesOutsideRoots: "a symbolic link in the path leads outside the allowed folders"
        case .redirectedBySymlink: "a symbolic link in the path leads to a different place"
        case .unresolvable: "a part of the path could not be resolved"
        case .rootUnavailable: "an allowed folder could not be resolved"
        }
    }
}

/// A path that passed `PathGuard`. `url` is the fully resolved path, with no symbolic link left in it.
/// Only `PathGuard` creates one, so a function that takes an `ApprovedPath` never sees an unchecked path.
public struct ApprovedPath: Hashable, Sendable {
    public let url: URL
    /// The text the path came from, before expansion and resolution.
    public let text: String
}
