import CryptoKit
import Foundation

/// SHA-256 of a file.
enum FileDigest {
    private static let chunkSize = 1 << 20

    /// Reads the file in 1 MiB chunks, so a large installer never sits in memory whole.
    static func sha256(of file: URL) throws -> SHA256Digest {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard let digest = SHA256Digest(hex) else { preconditionFailure("SHA-256 always yields 64 hex characters") }
        return digest
    }
}
