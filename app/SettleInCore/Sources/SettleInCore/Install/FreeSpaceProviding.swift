import Foundation

/// Reports the free space on a volume. Tests supply a fake to force the not-enough-space path.
public protocol FreeSpaceProviding: Sendable {
    /// The bytes available on the volume that holds `url`. `url` must exist.
    func availableBytes(onVolumeOf url: URL) throws -> Int64
}

public struct VolumeFreeSpace: FreeSpaceProviding {
    public init() {}

    public func availableBytes(onVolumeOf url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values.volumeAvailableCapacityForImportantUsage else {
            throw InstallError.freeSpaceUnreadable(path: url.path)
        }
        return bytes
    }
}
