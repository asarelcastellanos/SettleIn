import Foundation
import Testing
@testable import SettleInCore

/// The stub keeps global state, so the tests in this suite run one at a time.
@Suite(.serialized)
struct DownloaderTests {
    private static let fileURL = "https://downloads.example.com/App-1.0.dmg"
    private static let zeroDigest = String(repeating: "0", count: 64)

    private static func hello(status: Int = 200, hold: Bool = false) -> DownloadStub.Route {
        .body(status: status, chunks: [Data("hello".utf8)], contentLength: 5, hold: hold)
    }

    private static func downloader(root: URL) -> Downloader {
        Downloader(configuration: DownloadStub.configuration(), temporaryRoot: root)
    }

    /// Runs a download whose body only records the file's directory and contents.
    private static func fetch(
        _ source: CatalogDownload,
        hosts: [AllowedHost],
        root: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> DownloadResult<String> {
        try await downloader(root: root).withDownload(source: source, allowedHosts: hosts, progress: progress) { file in
            try String(contentsOf: file, encoding: .utf8)
        }
    }

    // MARK: HTTPS only

    @Test func httpURLThrowsInsecureSchemeWithoutAnyRequest() async throws {
        DownloadStub.reset(routes: [:])
        let source = try downloadSource("http://downloads.example.com/App.dmg", sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        try await withDownloadScratchRoot { root in
            await #expect(throws: DownloadError.insecureScheme) {
                _ = try await Self.fetch(source, hosts: hosts, root: root)
            }
            #expect(downloadEntries(in: root).isEmpty)
        }
        #expect(DownloadStub.requestedURLs.isEmpty)
    }

    @Test func unlistedFirstHostThrowsDisallowedHostWithoutAnyRequest() async throws {
        DownloadStub.reset(routes: [:])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("cdn.example.org")
        try await withDownloadScratchRoot { root in
            await #expect(throws: DownloadError.disallowedHost("downloads.example.com")) {
                _ = try await Self.fetch(source, hosts: hosts, root: root)
            }
        }
        #expect(DownloadStub.requestedURLs.isEmpty)
    }

    // MARK: Redirects

    @Test func redirectToAnotherAllowedHostSucceeds() async throws {
        DownloadStub.reset(routes: [
            Self.fileURL: .redirect(target: "https://objects.example.com/App-1.0.dmg"),
            "https://objects.example.com/App-1.0.dmg": Self.hello()
        ])
        let source = try downloadSource(Self.fileURL, sha256: downloadHelloDigest)
        let hosts = try downloadHosts("downloads.example.com", "objects.example.com")
        try await withDownloadScratchRoot { root in
            let result = try await Self.fetch(source, hosts: hosts, root: root)
            #expect(result.value == "hello")
        }
        #expect(DownloadStub.requestedURLs == [Self.fileURL, "https://objects.example.com/App-1.0.dmg"])
    }

    @Test func redirectToUnlistedHostThrowsDisallowedRedirect() async throws {
        DownloadStub.reset(routes: [
            Self.fileURL: .redirect(target: "https://evil.example.net/App-1.0.dmg"),
            "https://evil.example.net/App-1.0.dmg": Self.hello()
        ])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        try await withDownloadScratchRoot { root in
            await #expect(throws: DownloadError.disallowedRedirect("evil.example.net")) {
                _ = try await Self.fetch(source, hosts: hosts, root: root)
            }
            #expect(downloadEntries(in: root).isEmpty)
        }
        #expect(DownloadStub.requestedURLs == [Self.fileURL])
    }

    @Test func redirectToHTTPThrowsDisallowedRedirect() async throws {
        DownloadStub.reset(routes: [
            Self.fileURL: .redirect(target: "http://downloads.example.com/App-1.0.dmg"),
            "http://downloads.example.com/App-1.0.dmg": Self.hello()
        ])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        try await withDownloadScratchRoot { root in
            await #expect(throws: DownloadError.disallowedRedirect("downloads.example.com")) {
                _ = try await Self.fetch(source, hosts: hosts, root: root)
            }
            #expect(downloadEntries(in: root).isEmpty)
        }
        #expect(DownloadStub.requestedURLs == [Self.fileURL])
    }

    // MARK: Status and digest

    @Test func statusOtherThan200ThrowsUnexpectedStatus() async throws {
        DownloadStub.reset(routes: [Self.fileURL: Self.hello(status: 404)])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        try await withDownloadScratchRoot { root in
            await #expect(throws: DownloadError.unexpectedStatus(404)) {
                _ = try await Self.fetch(source, hosts: hosts, root: root)
            }
            #expect(downloadEntries(in: root).isEmpty)
        }
    }

    @Test func wrongDigestThrowsDigestMismatchAndRemovesTheDirectory() async throws {
        DownloadStub.reset(routes: [Self.fileURL: Self.hello()])
        let source = try downloadSource(Self.fileURL, sha256: Self.zeroDigest)
        let hosts = try downloadHosts("downloads.example.com")
        let expected = try #require(SHA256Digest(Self.zeroDigest))
        let actual = try #require(SHA256Digest(downloadHelloDigest))
        try await withDownloadScratchRoot { root in
            let bodyRan = BodyFlag()
            await #expect(throws: DownloadError.digestMismatch(expected: expected, actual: actual)) {
                _ = try await Self.downloader(root: root).withDownload(source: source, allowedHosts: hosts) { _ in
                    bodyRan.set()
                }
            }
            #expect(!bodyRan.value)
            #expect(downloadEntries(in: root).isEmpty)
        }
    }

    @Test func matchingDigestReportsVerified() async throws {
        DownloadStub.reset(routes: [Self.fileURL: Self.hello()])
        let source = try downloadSource(Self.fileURL, sha256: downloadHelloDigest)
        let hosts = try downloadHosts("downloads.example.com")
        let digest = try #require(SHA256Digest(downloadHelloDigest))
        try await withDownloadScratchRoot { root in
            let result = try await Self.fetch(source, hosts: hosts, root: root)
            #expect(result.value == "hello")
            #expect(result.integrity == .verified(digest))
        }
    }

    @Test func noPinnedDigestReportsUnpinned() async throws {
        DownloadStub.reset(routes: [Self.fileURL: Self.hello()])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        try await withDownloadScratchRoot { root in
            let result = try await Self.fetch(source, hosts: hosts, root: root)
            #expect(result.value == "hello")
            #expect(result.integrity == .unpinned)
        }
    }

    // MARK: Private directory

    @Test func directoryIsMode0700WhileBodyRuns() async throws {
        DownloadStub.reset(routes: [Self.fileURL: Self.hello()])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        try await withDownloadScratchRoot { root in
            let downloader = Self.downloader(root: root)
            let result = try await downloader.withDownload(source: source, allowedHosts: hosts) { file in
                let directory = file.deletingLastPathComponent()
                return (
                    try downloadStatMode(of: directory),
                    directory.lastPathComponent.hasPrefix("SettleIn-"),
                    file.lastPathComponent
                )
            }
            #expect(result.value.0 == "700")
            #expect(result.value.1)
            #expect(result.value.2 == "App-1.0.dmg")
        }
    }

    @Test func directoryIsGoneAfterSuccessfulBody() async throws {
        DownloadStub.reset(routes: [Self.fileURL: Self.hello()])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        try await withDownloadScratchRoot { root in
            let directory = try await Self.downloader(root: root).withDownload(source: source, allowedHosts: hosts) {
                $0.deletingLastPathComponent()
            }.value
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            #expect(downloadEntries(in: root).isEmpty)
        }
    }

    @Test func directoryIsGoneAfterThrowingBody() async throws {
        struct BodyFailure: Error {}
        DownloadStub.reset(routes: [Self.fileURL: Self.hello()])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        try await withDownloadScratchRoot { root in
            await #expect(throws: BodyFailure.self) {
                _ = try await Self.downloader(root: root).withDownload(source: source, allowedHosts: hosts) { _ in
                    throw BodyFailure()
                }
            }
            #expect(downloadEntries(in: root).isEmpty)
        }
    }

    @Test func defaultDownloaderUsesTheSystemTemporaryDirectory() async throws {
        DownloadStub.reset(routes: [Self.fileURL: Self.hello()])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        let downloader = Downloader(
            configuration: DownloadStub.configuration(),
            temporaryRoot: FileManager.default.temporaryDirectory
        )
        let directory = try await downloader.withDownload(source: source, allowedHosts: hosts) {
            $0.deletingLastPathComponent()
        }.value
        #expect(directory.deletingLastPathComponent().standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL)
        #expect(directory.lastPathComponent.hasPrefix("SettleIn-"))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: Progress and cancel

    @Test func progressNeverDecreasesAndEndsAtTheTotal() async throws {
        let chunks = ["he", "l", "lo"].map { Data($0.utf8) }
        DownloadStub.reset(routes: [Self.fileURL: .body(status: 200, chunks: chunks, contentLength: 5, hold: false)])
        let source = try downloadSource(Self.fileURL, sha256: downloadHelloDigest)
        let hosts = try downloadHosts("downloads.example.com")
        let recorder = DownloadProgressRecorder()
        try await withDownloadScratchRoot { root in
            _ = try await Self.fetch(source, hosts: hosts, root: root, progress: { recorder.record($0) })
        }
        let values = recorder.values
        #expect(values.last == DownloadProgress(bytesReceived: 5, totalBytes: 5))
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.bytesReceived <= $1.bytesReceived })
        #expect(values.allSatisfy { $0.totalBytes == 5 })
    }

    @Test func unknownTotalIsNilNotZero() async throws {
        DownloadStub.reset(routes: [
            Self.fileURL: .body(status: 200, chunks: [Data("hello".utf8)], contentLength: nil, hold: false)
        ])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        let recorder = DownloadProgressRecorder()
        try await withDownloadScratchRoot { root in
            _ = try await Self.fetch(source, hosts: hosts, root: root, progress: { recorder.record($0) })
        }
        #expect(!recorder.values.isEmpty)
        #expect(recorder.values.allSatisfy { $0.totalBytes == nil })
        #expect(recorder.values.last?.bytesReceived == 5)
    }

    @Test func cancellingMidTransferStopsTheTransferAndRemovesTheDirectory() async throws {
        DownloadStub.reset(routes: [
            Self.fileURL: .body(status: 200, chunks: [Data(count: 65_536)], contentLength: 1_048_576, hold: true)
        ])
        let source = try downloadSource(Self.fileURL, sha256: nil)
        let hosts = try downloadHosts("downloads.example.com")
        let recorder = DownloadProgressRecorder()
        try await withDownloadScratchRoot { root in
            let bodyRan = BodyFlag()
            let downloader = Self.downloader(root: root)
            let task = Task {
                try await downloader.withDownload(
                    source: source,
                    allowedHosts: hosts,
                    progress: { recorder.record($0) },
                    body: { _ in bodyRan.set() }
                )
            }
            let started = await recorder.waitForBytes(atLeast: 65_536)
            #expect(started)
            #expect(downloadEntries(in: root).count == 1)
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(!bodyRan.value)
            #expect(downloadEntries(in: root).isEmpty)
        }
        #expect(DownloadStub.stopCount >= 1)
    }
}

/// A flag that the body closure sets, readable after the download returns.
private final class BodyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }

    func set() {
        lock.withLock { flag = true }
    }
}
