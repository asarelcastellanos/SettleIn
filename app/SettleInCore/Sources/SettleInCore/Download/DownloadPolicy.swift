import Foundation

/// The rules for which URLs a download may use. These are pure functions of the URL and the allowed hosts.
enum DownloadPolicy {
    /// Throws when the first URL is not `https` or names a host that is not allowed.
    static func checkFirstURL(_ url: URL, allowedHosts: [AllowedHost]) throws {
        guard isHTTPS(url) else { throw DownloadError.insecureScheme }
        guard isAllowed(url, allowedHosts: allowedHosts) else {
            throw DownloadError.disallowedHost(hostName(of: url))
        }
    }

    /// The error for a redirect target, or `nil` when the target is `https` and its host is allowed.
    static func redirectViolation(_ url: URL, allowedHosts: [AllowedHost]) -> DownloadError? {
        isHTTPS(url) && isAllowed(url, allowedHosts: allowedHosts)
            ? nil
            : .disallowedRedirect(hostName(of: url))
    }

    /// A safe file name for the download. The server's path decides it, so the name keeps only
    /// letters, digits, dot, hyphen, and underscore, and never starts with a dot.
    static func fileName(for url: URL) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let cleaned = url.lastPathComponent.filter { allowed.contains($0) }
        let trimmed = String(cleaned.drop { $0 == "." }.prefix(100))
        return trimmed.isEmpty ? "download" : trimmed
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    private static func isAllowed(_ url: URL, allowedHosts: [AllowedHost]) -> Bool {
        allowedHosts.contains { $0.matches(url) }
    }

    private static func hostName(of url: URL) -> String {
        url.host(percentEncoded: false)?.lowercased() ?? ""
    }
}
