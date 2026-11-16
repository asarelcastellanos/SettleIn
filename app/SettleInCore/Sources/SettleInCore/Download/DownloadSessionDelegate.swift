import Foundation

/// Receives one transfer's callbacks. It checks every redirect and the status code, writes the body to
/// `handle`, reports progress, and resumes the continuation once with the transfer's outcome.
final class DownloadSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let allowedHosts: [AllowedHost]
    private let handle: FileHandle
    private let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var tracker = DownloadProgressTracker()
    private var failure: DownloadError?
    private var continuation: CheckedContinuation<Void, Error>?

    init(allowedHosts: [AllowedHost], handle: FileHandle, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.allowedHosts = allowedHosts
        self.handle = handle
        self.progress = progress
    }

    /// Stores the continuation, then starts the task.
    func start(_ task: URLSessionTask, continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url else {
            fail(.disallowedRedirect(""), cancelling: task)
            completionHandler(nil)
            return
        }
        if let violation = DownloadPolicy.redirectViolation(target, allowedHosts: allowedHosts) {
            fail(violation, cancelling: task)
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            fail(.unexpectedStatus(status), cancelling: dataTask)
            completionHandler(.cancel)
            return
        }
        report { $0.announce(expectedLength: response.expectedContentLength) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            fail(.fileWriteFailed, cancelling: dataTask)
            return
        }
        report { $0.receive(byteCount: data.count) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (recorded, continuation) = lock.withLock { () -> (DownloadError?, CheckedContinuation<Void, Error>?) in
            defer { self.continuation = nil }
            return (failure, self.continuation)
        }
        if let recorded {
            continuation?.resume(throwing: recorded)
        } else if let urlError = error as? URLError, urlError.code == .cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error {
            let code = (error as? URLError)?.errorCode ?? (error as NSError).code
            continuation?.resume(throwing: DownloadError.transferFailed(code: code))
        } else {
            continuation?.resume()
        }
    }

    /// Keeps the first failure and cancels the task. `didCompleteWithError` then reports the failure.
    private func fail(_ error: DownloadError, cancelling task: URLSessionTask) {
        lock.withLock {
            if failure == nil { failure = error }
        }
        task.cancel()
    }

    private func report(_ update: (inout DownloadProgressTracker) -> DownloadProgress) {
        let value = lock.withLock { update(&tracker) }
        progress(value)
    }
}
