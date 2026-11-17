import Foundation

/// The three folders an uninstall path may sit in.
enum UninstallRoot: CaseIterable, Sendable {
    case applications, library, config
}

/// The shape rules for the part of an uninstall path below its root. `UninstallPath` applies them to catalog
/// text, and `PathGuard` applies them again to the path it resolves, so both use this one list.
///
/// - `/Applications` holds only `/Applications/<Name>.app`. A path that reaches into a bundle there is
///   `insideAppBundle`.
/// - `~/Library` holds only paths that start with one of `allowedLibraryFolders` and go at least one level
///   deeper. A direct child of `~/Library` is a separate rule, because it names the whole folder.
/// - `~/.config` holds any path below it. The caller has already rejected `~/.config` itself.
///
/// A folder under `~/Library` or `~/.config` may have a name that ends in `.app`, such as
/// `~/Library/Containers/com.vendor.app`. The names alone do not decide. The uninstaller looks at the disk and
/// treats a `.app` folder as a bundle only when it holds `Contents/Info.plist`.
enum UninstallPathShape {
    enum Violation: Equatable, Sendable {
        case insideAppBundle
        case libraryFolderNotAllowed
        case notAnApplication
    }

    /// The first folder of a path below `~/Library`. Folders that hold credentials, iCloud Drive, mail, and
    /// other data the user owns are not on this list.
    static let allowedLibraryFolders: Set<String> = [
        "Application Support", "Caches", "Preferences", "Logs", "Containers",
        "Saved Application State", "HTTPStorages", "WebKit", "Cookies"
    ]

    /// `relative` holds the components below the root. The caller has already rejected an empty list and a
    /// direct child of `~/Library`. The folder names are compared with their letter case.
    static func violation(root: UninstallRoot, relative: [String]) -> Violation? {
        switch root {
        case .applications:
            if relative.dropLast().contains(where: isAppName) { return .insideAppBundle }
            guard relative.count == 1, let name = relative.first, isAppName(name), name.count > appSuffix.count
            else { return .notAnApplication }
        case .library:
            guard let first = relative.first, allowedLibraryFolders.contains(first) else {
                return .libraryFolderNotAllowed
            }
        case .config:
            break
        }
        return nil
    }

    private static let appSuffix = ".app"

    /// True when the component ends in `.app`, in any letter case.
    static func isAppName(_ component: String) -> Bool {
        component.lowercased().hasSuffix(appSuffix)
    }
}
