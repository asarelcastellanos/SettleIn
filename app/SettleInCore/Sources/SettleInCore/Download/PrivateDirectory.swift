import Foundation

/// A fresh directory that only the current user can use.
enum PrivateDirectory {
    static let namePrefix = "SettleIn-"

    /// Creates `SettleIn-<random>` under `root` with mode 0700, then reads the mode and owner back.
    /// The directory is removed again when the read-back fails.
    static func create(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(namePrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw DownloadError.privateDirectoryFailed(reason: "the directory could not be created")
        }
        do {
            try verify(directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return directory
    }

    /// Throws unless `directory` is a real directory (not a symlink) with mode 0700 owned by this user.
    static func verify(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw DownloadError.privateDirectoryFailed(reason: "the directory could not be read back")
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw DownloadError.privateDirectoryFailed(reason: "the path is not a directory")
        }
        guard info.st_mode & 0o7777 == 0o700 else {
            throw DownloadError.privateDirectoryFailed(reason: "the directory is not mode 0700")
        }
        guard info.st_uid == getuid() else {
            throw DownloadError.privateDirectoryFailed(reason: "another user owns the directory")
        }
    }
}
