import Foundation
import Testing
@testable import SettleInCore

/// SHA-256 of the ASCII text "hello".
let downloadHelloDigest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

/// In-memory replacement for the network. Routes are keyed by the full URL string. The suite that uses it
/// runs serialized because the state is global.
enum DownloadStub {
    enum Route {
        /// Sends the chunks in order. `hold` keeps the transfer open after the last chunk until it is cancelled.
        case body(status: Int, chunks: [Data], contentLength: Int64?, hold: Bool)
        case redirect(target: String)
    }

    private struct State {
        var routes: [String: Route] = [:]
        var requestedURLs: [String] = []
        var stopCount = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset(routes: [String: Route]) {
        lock.withLock { state = State(routes: routes) }
    }

    static var requestedURLs: [String] { lock.withLock { state.requestedURLs } }
    static var stopCount: Int { lock.withLock { state.stopCount } }

    fileprivate static func route(for url: URL) -> Route? {
        lock.withLock {
            state.requestedURLs.append(url.absoluteString)
            return state.routes[url.absoluteString]
        }
    }

    fileprivate static func recordStop() {
        lock.withLock { state.stopCount += 1 }
    }

    /// An ephemeral configuration whose only protocol is the stub.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadStubProtocol.self]
        return configuration
    }
}

final class DownloadStubProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let route = DownloadStub.route(for: url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch route {
        case .redirect(let target):
            redirect(from: url, to: target)
        case .body(let status, let chunks, let contentLength, let hold):
            send(url: url, status: status, chunks: chunks, contentLength: contentLength, hold: hold)
        }
    }

    override func stopLoading() {
        DownloadStub.recordStop()
    }

    private func redirect(from url: URL, to target: String) {
        guard let targetURL = URL(string: target),
              let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: targetURL), redirectResponse: response)
    }

    private func send(url: URL, status: Int, chunks: [Data], contentLength: Int64?, hold: Bool) {
        var headers: [String: String] = [:]
        if let contentLength { headers["Content-Length"] = String(contentLength) }
        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if !hold {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// Collects progress values from the downloader's background queue.
final class DownloadProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [DownloadProgress] = []

    var values: [DownloadProgress] { lock.withLock { recorded } }

    func record(_ value: DownloadProgress) {
        lock.withLock { recorded.append(value) }
    }

    /// Waits until some recorded value has at least `bytes` bytes. Returns false after the timeout.
    func waitForBytes(atLeast bytes: Int64, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if values.contains(where: { $0.bytesReceived >= bytes }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// Runs `work` with an empty scratch directory standing in for the temp directory, then removes it.
/// The directory name avoids the `SettleIn` prefix so a leaked private directory shows up on its own.
@discardableResult
func withDownloadScratchRoot<Result>(_ work: (URL) async throws -> Result) async throws -> Result {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await work(root)
}

/// The names inside `root`. An unreadable root reports a marker name so a test cannot pass by accident.
func downloadEntries(in root: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? ["<unreadable>"]
}

/// Runs `stat -f %Lp` and returns the octal mode it prints.
func downloadStatMode(of url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/stat")
    process.arguments = ["-f", "%Lp", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func downloadSource(_ url: String, sha256: String?) throws -> CatalogDownload {
    let parsedURL = try #require(URL(string: url))
    let digest = try sha256.map { try #require(SHA256Digest($0)) }
    return CatalogDownload(url: parsedURL, sha256: digest)
}

func downloadHosts(_ names: String...) throws -> [AllowedHost] {
    try names.map { try #require(AllowedHost($0)) }
}
