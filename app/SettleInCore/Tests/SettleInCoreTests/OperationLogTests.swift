import Foundation
import Testing
@testable import SettleInCore

struct OperationLogTests {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func eachLineStartsWithAnIsoTimestamp() {
        var log = OperationLog(homeDirectory: "/Users/tester")
        log.append("install requested", at: Self.date)
        log.append("state: idle -> downloading", at: Self.date.addingTimeInterval(5))

        #expect(log.text == """
            2027-01-15T08:00:00Z install requested
            2027-01-15T08:00:05Z state: idle -> downloading
            """)
    }

    @Test func theHomeDirectoryBecomesATilde() {
        var log = OperationLog(homeDirectory: "/Users/tester")
        log.append("moved /Users/tester/Library/Caches/example to the Trash", at: Self.date)
        #expect(!log.text.contains("/Users/tester"))
        #expect(log.text.contains("~/Library/Caches/example"))
    }

    @Test func aHomeDirectoryWithATrailingSlashIsReplacedToo() {
        var log = OperationLog(homeDirectory: "/Users/tester/")
        log.append("/Users/tester/Library/x", at: Self.date)
        #expect(log.entries.first?.text == "~/Library/x")
    }

    @Test func aRootHomeDirectoryReplacesNothing() {
        var log = OperationLog(homeDirectory: "/")
        log.append("/Applications/Fixture.app", at: Self.date)
        #expect(log.entries.first?.text == "/Applications/Fixture.app")
    }

    @Test func textWithLineBreaksStaysOnOneLine() {
        var log = OperationLog(homeDirectory: "/Users/tester")
        log.append("first\n2027-01-15T08:00:00Z forged line\r\nthird", at: Self.date)
        #expect(log.entries.count == 1)
        #expect(!log.text.contains("\n"))
    }

    @Test func anEmptyLogHasEmptyText() {
        #expect(OperationLog(homeDirectory: "/Users/tester").text.isEmpty)
    }
}

struct OperationLogOrchestratorTests {
    private let home = "/Users/tester"

    @Test func aFailedRunLogsTheFailingToolAndItsExitCode() async throws {
        let failure = InstallError.signatureInvalid(.toolFailed(tool: "codesign", exitCode: 2))
        try await withDownloadScratchRoot { root in
            let harness = OrchestratorHarness(
                root: root,
                home: home,
                appInstaller: FakeAppInstaller(result: .failure(failure))
            )
            let app = OrchestratorFixture.app(.dmg)
            await harness.orchestrator.install(app)

            let text = await harness.orchestrator.log(for: app.id).text

            #expect(text.contains("tool codesign exited with code 2"))
            #expect(text.contains("state: verifying -> failed"))
            #expect(text.contains("install requested for \(app.name)"))
            #expect(text.contains("https://downloads.example.com/Fixture-1.0.dmg"))
        }
    }

    @Test func theLogHoldsNoHomeDirectoryPath() async throws {
        try await withDownloadScratchRoot { root in
            // The fake downloader's folder sits under the fake home, so the run uses a path in the home.
            let fakeHome = root.appendingPathComponent("home", isDirectory: true)
            try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: false)
            let harness = OrchestratorHarness(
                root: fakeHome,
                home: fakeHome.path,
                appInstaller: FakeAppInstaller(result: .failure(InstallError.replaceDeclined))
            )
            let app = OrchestratorFixture.app(.dmg)
            await harness.orchestrator.install(app)

            let text = await harness.orchestrator.log(for: app.id).text

            #expect(text.contains("downloaded to ~/FakeDownload-"))
            #expect(!text.contains(fakeHome.path))
            #expect(!text.contains(NSHomeDirectory()))
        }
    }

    @Test func theLogNeverRepeatsToolOutputFromAFailure() async throws {
        try await withDownloadScratchRoot { root in
            let hostile = InstallError.mountFailed(detail: "HOSTILE-TOOL-OUTPUT")
            let harness = OrchestratorHarness(root: root, appInstaller: FakeAppInstaller(result: .failure(hostile)))
            let app = OrchestratorFixture.app(.dmg)
            await harness.orchestrator.install(app)

            #expect(!(await harness.orchestrator.log(for: app.id).text).contains("HOSTILE-TOOL-OUTPUT"))
        }
    }

    @Test func aSuccessfulRunLogsEachStateChange() async throws {
        try await withDownloadScratchRoot { root in
            let harness = OrchestratorHarness(root: root)
            let app = OrchestratorFixture.app(.dmg)
            await harness.orchestrator.install(app)

            let text = await harness.orchestrator.log(for: app.id).text

            let changes = [
                "idle -> downloading", "downloading -> verifying", "verifying -> installing", "installing -> installed"
            ]
            for change in changes {
                #expect(text.contains("state: \(change)"))
            }
            #expect(text.contains("2027-01-15T08:00:00Z"))
            #expect(text.contains("matches the pinned SHA-256"))
        }
    }

    @Test func aNewOperationStartsANewLog() async throws {
        try await withDownloadScratchRoot { root in
            let harness = OrchestratorHarness(root: root, downloader: .failOnce(DownloadError.fileWriteFailed))
            let app = OrchestratorFixture.app(.dmg)
            await harness.orchestrator.install(app)
            #expect(await harness.orchestrator.log(for: app.id).text.contains("failed:"))

            await harness.orchestrator.install(app)

            #expect(!(await harness.orchestrator.log(for: app.id).text).contains("failed:"))
        }
    }

    @Test func anUnpinnedDownloadIsLoggedAsRelyingOnTheSignature() async throws {
        try await withDownloadScratchRoot { root in
            let source = DownloadSource.universal(OrchestratorFixture.download("Fixture.pkg", pinned: false))
            let harness = OrchestratorHarness(root: root)
            let app = OrchestratorFixture.app(.pkg, source: source)
            await harness.orchestrator.install(app)

            #expect(await harness.orchestrator.log(for: app.id).text.contains("pins no SHA-256"))
        }
    }
}
