import Foundation

/// Whether the downloaded file was compared with a pinned digest.
public enum DownloadIntegrity: Equatable, Sendable {
    /// The catalog pins a digest and the file matches it.
    case verified(SHA256Digest)
    /// The catalog pins no digest, so nothing proves the file's content.
    case unpinned
}

/// What `Downloader.withDownload` returns after the temporary directory is gone.
public struct DownloadResult<Value> {
    /// The value that `body` returned.
    public let value: Value
    public let integrity: DownloadIntegrity
}

extension DownloadResult: Sendable where Value: Sendable {}
extension DownloadResult: Equatable where Value: Equatable {}
