import Foundation

/// Downloads a catalog file over HTTPS into a private directory and checks its pinned SHA-256.
///
/// Every URL in the chain, the first one and each redirect, must use `https` and name an allowed host.
/// The directory exists only while `body` runs.
public struct Downloader: @unchecked Sendable {
    // `configuration` is a private copy that no code mutates after `init`.
    private let configuration: URLSessionConfiguration
    private let temporaryRoot: URL

    public init() {
        self.init(configuration: .ephemeral, temporaryRoot: FileManager.default.temporaryDirectory)
    }

    /// Tests inject a configuration that carries a `URLProtocol` stub, and a root they can inspect.
    init(configuration: URLSessionConfiguration, temporaryRoot: URL) {
        // swiftlint:disable:next force_cast
        let copy = configuration.copy() as! URLSessionConfiguration
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.httpCookieStorage = nil
        copy.httpCookieAcceptPolicy = .never
        copy.httpShouldSetCookies = false
        copy.urlCredentialStorage = nil
        self.configuration = copy
        self.temporaryRoot = temporaryRoot
    }

    /// Downloads `source` into a new private directory, checks the digest, runs `body` with the file's URL,
    /// and removes the directory before it returns or throws, including when `body` throws or the task is
    /// cancelled.
    ///
    /// - Parameters:
    ///   - source: The catalog download. Its digest, when present, is checked before `body` runs.
    ///   - allowedHosts: The hosts the catalog entry allows, for the first URL and every redirect.
    ///   - progress: Called on a background queue. Both numbers never decrease.
    ///   - body: Receives the local file URL. The file is gone after `body` returns.
    public func withDownload<Value>(
        source: CatalogDownload,
        allowedHosts: [AllowedHost],
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in },
        body: (URL) async throws -> Value
    ) async throws -> DownloadResult<Value> {
        try DownloadPolicy.checkFirstURL(source.url, allowedHosts: allowedHosts)
        let directory = try PrivateDirectory.create(in: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent(DownloadPolicy.fileName(for: source.url))
        try await transfer(from: source.url, to: file, allowedHosts: allowedHosts, progress: progress)
        let integrity = try verify(file, against: source.sha256)
        return DownloadResult(value: try await body(file), integrity: integrity)
    }

    private func verify(_ file: URL, against pinned: SHA256Digest?) throws -> DownloadIntegrity {
        guard let pinned else { return .unpinned }
        let actual = try FileDigest.sha256(of: file)
        guard actual == pinned else {
            try? FileManager.default.removeItem(at: file)
            throw DownloadError.digestMismatch(expected: pinned, actual: actual)
        }
        return .verified(pinned)
    }

    private func transfer(
        from url: URL,
        to file: URL,
        allowedHosts: [AllowedHost],
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: file)
        else { throw DownloadError.fileWriteFailed }
        defer { try? handle.close() }

        let delegate = DownloadSessionDelegate(allowedHosts: allowedHosts, handle: handle, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task, continuation: continuation)
                // A cancel that arrived before `resume` had nothing to stop, so repeat it.
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            task.cancel()
        }
    }
}
