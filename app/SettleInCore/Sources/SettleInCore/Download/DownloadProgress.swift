import Foundation

/// How much of a download has arrived.
public struct DownloadProgress: Equatable, Sendable {
    public let bytesReceived: Int64
    /// The size the server announced, or `nil` when it did not announce one.
    public let totalBytes: Int64?
}

/// Builds `DownloadProgress` values. Neither number ever goes down.
struct DownloadProgressTracker {
    private var received: Int64 = 0
    private var total: Int64?

    /// Records the announced length. A negative length means the server gave none.
    mutating func announce(expectedLength: Int64) -> DownloadProgress {
        if expectedLength >= 0 {
            total = max(total ?? 0, expectedLength)
        }
        return current
    }

    mutating func receive(byteCount: Int) -> DownloadProgress {
        received += Int64(byteCount)
        if let announced = total, received > announced {
            total = received
        }
        return current
    }

    private var current: DownloadProgress {
        DownloadProgress(bytesReceived: received, totalBytes: total)
    }
}
