import Foundation

/// The reason a download failed. Cancelling the Swift task throws `CancellationError`, not a `DownloadError`.
public enum DownloadError: Error, Equatable, Sendable {
    /// The URL does not use `https`. The downloader opens no connection.
    case insecureScheme
    /// The first URL names a host that is not in the allowed hosts.
    case disallowedHost(String)
    /// A redirect left `https` or named a host that is not in the allowed hosts. The value is the redirect's host.
    case disallowedRedirect(String)
    /// The server answered with a status other than 200.
    case unexpectedStatus(Int)
    /// The file's SHA-256 differs from the pinned digest. The downloader deleted the file.
    case digestMismatch(expected: SHA256Digest, actual: SHA256Digest)
    /// The transfer failed. The value is the `URLError` code.
    case transferFailed(code: Int)
    /// The downloader could not write the file.
    case fileWriteFailed
    /// The private directory could not be created, or it is not mode 0700 and owned by the current user.
    case privateDirectoryFailed(reason: String)
}
