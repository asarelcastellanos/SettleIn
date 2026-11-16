import Foundation

/// Checks on the files that an archive unpacked.
enum UnpackedItems {
    /// Throws `unsafeArchiveItem` when a symbolic link under `folder` resolves to a path outside `folder`.
    /// The walk does not follow links. Every other item sits under `folder` by construction.
    static func verifyContained(in folder: URL) throws {
        let root = folder.resolvingSymlinksInPath().path
        try walk(folder, root: root.hasSuffix("/") ? root : root + "/")
    }

    private static func walk(_ directory: URL, root: String) throws {
        let manager = FileManager.default
        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw InstallError.unsafeArchiveItem(path: directory.lastPathComponent)
        }
        for name in names {
            let item = directory.appendingPathComponent(name)
            let type = try? manager.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                try verifyLink(item, root: root)
            } else if type == .typeDirectory {
                try walk(item, root: root)
            }
        }
    }

    private static func verifyLink(_ link: URL, root: String) throws {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            throw InstallError.unsafeArchiveItem(path: link.lastPathComponent)
        }
        let absolute = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : URL(fileURLWithPath: target, relativeTo: link.deletingLastPathComponent())
        let resolved = absolute.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root) || resolved + "/" == root else {
            throw InstallError.unsafeArchiveItem(path: link.lastPathComponent + " -> " + target)
        }
    }

    /// The size of the app on disk. Symbolic links count as links and are not followed.
    static func allocatedSize(of app: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in walker {
            let size = try? item.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize
            total += Int64(size ?? 0)
        }
        return total
    }
}
