import Foundation
import Testing
@testable import SettleInCore

struct DownloadHelpersTests {
    @Test func fileNameKeepsASafeLastPathComponent() throws {
        let url = try #require(URL(string: "https://example.com/files/App-1.0_x64.dmg?token=a"))
        #expect(DownloadPolicy.fileName(for: url) == "App-1.0_x64.dmg")
    }

    @Test func fileNameFallsBackForDotsAndEmptyNames() throws {
        for text in ["https://example.com/..", "https://example.com/", "https://example.com/%2F%00"] {
            let url = try #require(URL(string: text))
            #expect(DownloadPolicy.fileName(for: url) == "download")
        }
    }

    @Test func trackerKeepsAnUnknownTotalNil() {
        var tracker = DownloadProgressTracker()
        #expect(tracker.announce(expectedLength: -1) == DownloadProgress(bytesReceived: 0, totalBytes: nil))
        #expect(tracker.receive(byteCount: 4) == DownloadProgress(bytesReceived: 4, totalBytes: nil))
    }

    @Test func trackerRaisesTheTotalWhenMoreBytesArrive() {
        var tracker = DownloadProgressTracker()
        _ = tracker.announce(expectedLength: 3)
        #expect(tracker.receive(byteCount: 5) == DownloadProgress(bytesReceived: 5, totalBytes: 5))
    }

    @Test func privateDirectoryRejectsAWiderMode() throws {
        let name = "DownloadTests-" + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: DownloadError.privateDirectoryFailed(reason: "the directory is not mode 0700")) {
            try PrivateDirectory.verify(directory)
        }
    }
}
