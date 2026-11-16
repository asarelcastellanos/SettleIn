import Foundation

/// Resolves symbolic links in a path that may not exist yet.
enum PathResolution {
    /// Splits a path on `/` and drops empty and `.` components.
    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
    }

    /// Resolves the longest existing prefix of `components` with `realpath`, then appends the rest unchanged.
    /// Returns nil when the first missing component exists anyway, which happens for a symbolic link that
    /// points at nothing and for a folder the process cannot read.
    static func resolve(_ components: [String]) -> [String]? {
        var existing = components
        var missing: [String] = []
        while true {
            if let real = realPath("/" + existing.joined(separator: "/")) {
                let resolved = Self.components(of: real)
                if let first = missing.first, itemExists(atPath: "/" + (resolved + [first]).joined(separator: "/")) {
                    return nil
                }
                return resolved + missing
            }
            guard let last = existing.popLast() else { return nil }
            missing.insert(last, at: 0)
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when `lstat` finds the item, so a dangling symbolic link counts as present.
    private static func itemExists(atPath path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
