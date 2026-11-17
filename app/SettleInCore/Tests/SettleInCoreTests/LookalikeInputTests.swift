import Foundation
import Testing
@testable import SettleInCore

/// Names that look like an allowed host or an app name but are not. Each one must be refused.
struct LookalikeInputTests {
    private static let lookalikeHosts = ["evilgithub.com", "github.com.evil.net", "sub.github.com", "github.com."]

    private static func url(_ host: String) throws -> URL {
        try #require(URL(string: "https://\(host)/rxhanson/Rectangle.dmg"))
    }

    // MARK: Hosts

    @Test(arguments: lookalikeHosts)
    func allowedHostDoesNotMatchALookalike(_ host: String) throws {
        let allowed = try #require(AllowedHost("github.com"))
        #expect(!allowed.matches(try Self.url(host)))
    }

    @Test func allowedHostMatchesItselfInAnyLetterCase() throws {
        let allowed = try #require(AllowedHost("github.com"))
        #expect(allowed.matches(try Self.url("github.com")))
        #expect(allowed.matches(try Self.url("GitHub.COM")))
    }

    @Test func aUserNameInTheURLDoesNotMakeAnotherHostMatch() throws {
        let allowed = try #require(AllowedHost("github.com"))
        let url = try #require(URL(string: "https://github.com@evil.net/Rectangle.dmg"))
        #expect(!allowed.matches(url))
    }

    @Test(arguments: lookalikeHosts)
    func theRedirectCheckRefusesALookalike(_ host: String) throws {
        let allowed = try downloadHosts("github.com")
        let violation = DownloadPolicy.redirectViolation(try Self.url(host), allowedHosts: allowed)
        guard case .disallowedRedirect = violation else {
            Issue.record("\(host) was not refused as a redirect: \(String(describing: violation))")
            return
        }
    }

    @Test(arguments: lookalikeHosts)
    func theFirstURLCheckRefusesALookalike(_ host: String) throws {
        let allowed = try downloadHosts("github.com")
        #expect(throws: DownloadError.self) {
            try DownloadPolicy.checkFirstURL(try Self.url(host), allowedHosts: allowed)
        }
    }

    @Test func theRedirectCheckAcceptsTheAllowedHost() throws {
        let allowed = try downloadHosts("github.com")
        #expect(DownloadPolicy.redirectViolation(try Self.url("github.com"), allowedHosts: allowed) == nil)
    }

    // MARK: App names

    @Test(arguments: ["../Evil.app", "a/b.app", "a\\b.app", "", "Evil", "Evil.app.zip", ".app", "Ev\nil.app"])
    func appBundleNameRejectsOtherText(_ raw: String) {
        #expect(AppBundleName(raw) == nil)
    }

    @Test(arguments: ["Rectangle.app", "Google Chrome.app", "a.app"])
    func appBundleNameAcceptsAFolderNameThatEndsInDotApp(_ raw: String) {
        #expect(AppBundleName(raw)?.rawValue == raw)
    }
}

extension DownloaderTests {
    @Test(arguments: ["evilgithub.com", "github.com.evil.net", "sub.github.com"])
    func aRedirectToALookalikeHostThrowsDisallowedRedirect(_ host: String) async throws {
        let first = "https://github.com/App-1.0.dmg"
        let target = "https://\(host)/App-1.0.dmg"
        DownloadStub.reset(routes: [
            first: .redirect(target: target),
            target: .body(status: 200, chunks: [Data("hello".utf8)], contentLength: 5, hold: false)
        ])
        let source = try downloadSource(first, sha256: nil)
        let hosts = try downloadHosts("github.com")
        try await withDownloadScratchRoot { root in
            let downloader = Downloader(configuration: DownloadStub.configuration(), temporaryRoot: root)
            await #expect(throws: DownloadError.disallowedRedirect(host)) {
                _ = try await downloader.withDownload(
                    source: source, allowedHosts: hosts, progress: { _ in }, body: { _ in }
                )
            }
            #expect(downloadEntries(in: root).isEmpty)
        }
        #expect(DownloadStub.requestedURLs == [first])
    }
}
