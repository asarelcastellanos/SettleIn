import Foundation

/// The three folders the uninstaller may remove things from. Production code uses `system`. Tests pass
/// folders inside a temporary directory, so a test never reaches the real `/Applications` or the real home.
public struct AllowedRoots: Equatable, Sendable {
    public let home: URL
    public let applications: URL
    public var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    public var config: URL { home.appendingPathComponent(".config", isDirectory: true) }

    public init(home: URL, applications: URL) {
        self.home = home
        self.applications = applications
    }

    /// `/Applications`, and the current user's `~/Library` and `~/.config`.
    public static var system: AllowedRoots {
        AllowedRoots(
            home: FileManager.default.homeDirectoryForCurrentUser,
            applications: URL(fileURLWithPath: "/Applications", isDirectory: true)
        )
    }
}
