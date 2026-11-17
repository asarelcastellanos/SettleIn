import Foundation
import Testing
@testable import SettleInCore

// MARK: Parsers on captured output

struct SignatureParserTests {
    @Test func developerIDAppHasTeamID() throws {
        let output = try Fixture.text("codesign-dv-developer-id-app.txt")
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: output) == "EQHXZ8M8AV")
    }

    @Test func adHocAppHasNoTeamID() throws {
        let output = try Fixture.text("codesign-dv-adhoc-app.txt")
        #expect(output.contains("TeamIdentifier=not set"))
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: output) == nil)
    }

    @Test func unsignedAppHasNoTeamID() throws {
        let output = try Fixture.text("codesign-dv-unsigned-app.txt")
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: output) == nil)
    }

    @Test func emptyOutputHasNoTeamID() {
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: "") == nil)
    }

    @Test func twoTeamIdentifierLinesAreAmbiguous() {
        let output = "TeamIdentifier=AAAAAAAAAA\nTeamIdentifier=BBBBBBBBBB\n"
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: output) == nil)
    }

    @Test func parserKeepsTheCaseItReads() {
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: "TeamIdentifier=aaaaaaaaaa\n") == "aaaaaaaaaa")
    }

    @Test func signedPackageHasTrustedStatusAndTeamID() throws {
        let output = try Fixture.text("pkgutil-signed-package.txt")
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: output) == .trusted(teamID: "XSYZ3E4B7D"))
    }

    @Test func unsignedPackageIsUnsigned() throws {
        let output = try Fixture.text("pkgutil-unsigned-package.txt")
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: output) == .unsigned)
    }

    @Test func unknownPackageStatusIsUntrusted() throws {
        let output = try Fixture.text("pkgutil-signed-package.txt")
            .replacingOccurrences(of: "signed by a developer certificate issued by Apple for distribution",
                                  with: "signed by a certificate that is not trusted")
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: output)
            == .untrusted(status: "signed by a certificate that is not trusted"))
    }

    @Test func packageWithoutOrWithTwoStatusLinesIsUnrecognized() throws {
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: "Package does not exist: /x\n") == .unrecognized)
        let signed = try Fixture.text("pkgutil-signed-package.txt")
        let doubled = signed + "   Status: no signature\n"
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: doubled) == .unrecognized)
    }

    @Test func packageWithoutInstallerLineHasNoTeamID() throws {
        let output = try Fixture.text("pkgutil-signed-package.txt")
            .replacingOccurrences(of: "Developer ID Installer", with: "Mac Developer Installer")
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: output) == .trusted(teamID: nil))
    }

    @Test func packageWithTwoInstallerLinesHasNoTeamID() throws {
        let signed = try Fixture.text("pkgutil-signed-package.txt")
        let output = signed + "    1. Developer ID Installer: Other (AAAAAAAAAA)\n"
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: output) == .trusted(teamID: nil))
    }
}

// MARK: Verifier with a fake runner

struct SignatureVerifierTests {
    @Test func validAppRunsThreeToolsInOrder() async throws {
        let runner = try goodAppRunner()
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .valid(expectedChrome))
        let path = appURL.path
        #expect(await runner.calls == [
            .init(tool: "codesign", arguments: ["--verify", "--deep", "--strict", "--verbose=2", path]),
            .init(tool: "codesign", arguments: ["-dv", "--verbose=4", path]),
            .init(tool: "spctl", arguments: ["--assess", "--type", "execute", "--verbose=4", path])
        ])
    }

    @Test func teamIDMismatchNamesBothIDs() async throws {
        let captured = try Fixture.text("codesign-dv-developer-id-app.txt")
            .replacingOccurrences(of: "EQHXZ8M8AV", with: "AAAAAAAAAA")
        let runner = FakeCommandRunner([
            "codesign --verify": CommandResult(exitCode: 0),
            "codesign -dv": CommandResult(exitCode: 0, stderr: captured),
            "spctl": CommandResult(exitCode: 0)
        ])
        let result = await SignatureVerifier(runner: runner)
            .verifyApp(at: appURL, expecting: teamID("BBBBBBBBBB"))
        #expect(result == .invalid(.teamIDMismatch(expected: "BBBBBBBBBB", actual: "AAAAAAAAAA")))
    }

    @Test func teamIDComparisonIsCaseSensitive() async throws {
        let runner = FakeCommandRunner([
            "codesign --verify": CommandResult(exitCode: 0),
            "codesign -dv": CommandResult(exitCode: 0, stderr: "TeamIdentifier=eqhxz8m8av\n"),
            "spctl": CommandResult(exitCode: 0)
        ])
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .invalid(.teamIDMismatch(expected: "EQHXZ8M8AV", actual: "eqhxz8m8av")))
    }

    @Test func spctlIsSkippedWhenVerifyFails() async throws {
        let runner = FakeCommandRunner([
            "codesign --verify": CommandResult(exitCode: 2, stderr: "usage error"),
            "codesign -dv": CommandResult(exitCode: 0),
            "spctl": CommandResult(exitCode: 0)
        ])
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .invalid(.toolFailed(tool: "codesign", exitCode: 2)))
        #expect(await runner.toolNames == ["codesign"])
        if case .invalid(let failure) = result { #expect(failure.reason.contains("codesign")) }
    }

    @Test func brokenSealIsBrokenSignatureAndStopsTheChecks() async throws {
        let runner = FakeCommandRunner([
            "codesign --verify": CommandResult(
                exitCode: 1, stderr: try Fixture.text("codesign-verify-tampered-app.txt"))
        ])
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .invalid(.brokenSignature(
            detail: "/fixture/path/tamper/Tiny.app: invalid Info.plist (plist or signature have been modified)"
        )))
        #expect(await runner.toolNames == ["codesign"])
    }

    @Test func unsignedAppIsUnsigned() async throws {
        let runner = FakeCommandRunner([
            "codesign --verify": CommandResult(
                exitCode: 1, stderr: try Fixture.text("codesign-verify-unsigned-app.txt"))
        ])
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .invalid(.unsigned))
        #expect(await runner.toolNames == ["codesign"])
    }

    @Test func adHocAppIsTeamIDMissingAndSpctlNeverRuns() async throws {
        let runner = FakeCommandRunner([
            "codesign --verify": CommandResult(exitCode: 0),
            "codesign -dv": CommandResult(exitCode: 0, stderr: try Fixture.text("codesign-dv-adhoc-app.txt")),
            "spctl": CommandResult(exitCode: 3, stderr: try Fixture.text("spctl-rejected-adhoc-app.txt"))
        ])
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .invalid(.teamIDMissing))
        #expect(await runner.toolNames == ["codesign", "codesign"])
    }

    @Test func gatekeeperRejectionCarriesTheDetail() async throws {
        let runner = try goodAppRunner(replacing: "spctl", with: CommandResult(
            exitCode: 3, stderr: try Fixture.text("spctl-rejected-unsigned-app.txt")))
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .invalid(.gatekeeperRejected(
            detail: "/fixture/path/unsigned/Tiny.app: rejected source=no usable signature")))
    }

    @Test func otherSpctlExitCodeIsToolFailed() async throws {
        let runner = try goodAppRunner(replacing: "spctl", with: CommandResult(exitCode: 5))
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .invalid(.toolFailed(tool: "spctl", exitCode: 5)))
    }

    @Test func toolThatCannotStartIsToolFailed() async {
        let runner = FakeCommandRunner([:], launchFailure: true)
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .invalid(.toolFailed(tool: "codesign", exitCode: SignatureFailure.toolDidNotStart)))
        if case .invalid(let failure) = result { #expect(failure.reason.contains("could not start")) }
    }

    @Test func longVerifyOutputKeepsMessageLinesOnly() async {
        let noise = (0..<500).map { "--validated:/Some/Deep/Path/\($0)" }.joined(separator: "\n")
        let runner = FakeCommandRunner([
            "codesign --verify": CommandResult(
                exitCode: 1, stdout: "file modified: /x", stderr: noise + "\n/x: bad seal\n")
        ])
        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)
        #expect(result == .invalid(.brokenSignature(detail: "file modified: /x /x: bad seal")))
    }

    // MARK: Packages

    @Test func signedPackagePasses() async throws {
        let runner = FakeCommandRunner([
            "pkgutil": CommandResult(exitCode: 0, stdout: try Fixture.text("pkgutil-signed-package.txt"))
        ])
        let result = await SignatureVerifier(runner: runner)
            .verifyPackage(at: packageURL, expecting: teamID("XSYZ3E4B7D"))
        #expect(result == .valid(teamID("XSYZ3E4B7D")))
        #expect(await runner.calls == [.init(tool: "pkgutil", arguments: ["--check-signature", packageURL.path])])
    }

    @Test func signedPackageWithOtherTeamIDIsMismatch() async throws {
        let runner = FakeCommandRunner([
            "pkgutil": CommandResult(exitCode: 0, stdout: try Fixture.text("pkgutil-signed-package.txt"))
        ])
        let result = await SignatureVerifier(runner: runner)
            .verifyPackage(at: packageURL, expecting: teamID("BBBBBBBBBB"))
        #expect(result == .invalid(.teamIDMismatch(expected: "BBBBBBBBBB", actual: "XSYZ3E4B7D")))
    }

    @Test func unsignedPackageIsUnsigned() async throws {
        let runner = FakeCommandRunner([
            "pkgutil": CommandResult(exitCode: 1, stdout: try Fixture.text("pkgutil-unsigned-package.txt"))
        ])
        let result = await SignatureVerifier(runner: runner).verifyPackage(at: packageURL, expecting: expectedChrome)
        #expect(result == .invalid(.unsigned))
    }

    @Test func missingPackageIsToolFailed() async {
        let runner = FakeCommandRunner([
            "pkgutil": CommandResult(exitCode: 1, stderr: "Package does not exist: /x\n")
        ])
        let result = await SignatureVerifier(runner: runner).verifyPackage(at: packageURL, expecting: expectedChrome)
        #expect(result == .invalid(.toolFailed(tool: "pkgutil", exitCode: 1)))
    }

    @Test func untrustedPackageStatusIsBrokenSignature() async throws {
        let output = try Fixture.text("pkgutil-signed-package.txt")
            .replacingOccurrences(of: "signed by a developer certificate issued by Apple for distribution",
                                  with: "signed by a certificate that is not trusted")
        let runner = FakeCommandRunner(["pkgutil": CommandResult(exitCode: 0, stdout: output)])
        let result = await SignatureVerifier(runner: runner)
            .verifyPackage(at: packageURL, expecting: teamID("XSYZ3E4B7D"))
        #expect(result == .invalid(.brokenSignature(detail: "signed by a certificate that is not trusted")))
    }

    @Test func trustedStatusWithNonzeroExitIsToolFailed() async throws {
        let runner = FakeCommandRunner([
            "pkgutil": CommandResult(exitCode: 2, stdout: try Fixture.text("pkgutil-signed-package.txt"))
        ])
        let result = await SignatureVerifier(runner: runner)
            .verifyPackage(at: packageURL, expecting: teamID("XSYZ3E4B7D"))
        #expect(result == .invalid(.toolFailed(tool: "pkgutil", exitCode: 2)))
    }

    @Test func packageWithoutInstallerCertificateIsTeamIDMissing() async throws {
        let output = try Fixture.text("pkgutil-signed-package.txt")
            .replacingOccurrences(of: "Developer ID Installer", with: "Mac Developer Installer")
        let runner = FakeCommandRunner(["pkgutil": CommandResult(exitCode: 0, stdout: output)])
        let result = await SignatureVerifier(runner: runner).verifyPackage(at: packageURL, expecting: expectedChrome)
        #expect(result == .invalid(.teamIDMissing))
    }

    // MARK: Reasons

    @Test func everyFailureHasAPlainReason() {
        let failures: [SignatureFailure] = [
            .unsigned, .brokenSignature(detail: "d"), .gatekeeperRejected(detail: "d"), .teamIDMissing,
            .teamIDMismatch(expected: "BBBBBBBBBB", actual: "AAAAAAAAAA"), .toolFailed(tool: "spctl", exitCode: 3)
        ]
        for failure in failures {
            #expect(!failure.reason.isEmpty)
            #expect(!failure.reason.contains("\u{2014}"))
        }
        let mismatch = SignatureFailure.teamIDMismatch(expected: "BBBBBBBBBB", actual: "AAAAAAAAAA").reason
        #expect(mismatch.contains("AAAAAAAAAA") && mismatch.contains("BBBBBBBBBB"))
    }
}

// MARK: Integration with the real tools

struct SignatureIntegrationTests {
    private let runner = ProcessCommandRunner()
    private let anyTeam = teamID("AAAAAAAAAA")

    /// Builds a tiny `.app` in a new temporary directory. The caller removes the directory.
    private func makeApp() throws -> (root: URL, app: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("settlein-sigtest-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Tiny.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleExecutable": "Tiny", "CFBundleIdentifier": "dev.settlein.tiny",
            "CFBundleName": "Tiny", "CFBundlePackageType": "APPL", "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Tiny")
        try Data("#!/usr/bin/true\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (root, app)
    }

    private func adHocSign(_ app: URL) async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-s", "-", app.path])
        #expect(result.exitCode == 0, "codesign -s - failed: \(result.stderr)")
    }

    @Test func unsignedAppIsUnsigned() async throws {
        let (root, app) = try makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await SignatureVerifier(runner: runner).verifyApp(at: app, expecting: anyTeam)
        #expect(result == .invalid(.unsigned))
    }

    @Test func adHocSignedAppIsTeamIDMissing() async throws {
        let (root, app) = try makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        try await adHocSign(app)
        let result = await SignatureVerifier(runner: runner).verifyApp(at: app, expecting: anyTeam)
        #expect(result == .invalid(.teamIDMissing))
    }

    @Test func appChangedAfterSigningIsBrokenSignature() async throws {
        let (root, app) = try makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        try await adHocSign(app)
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let handle = try FileHandle(forWritingTo: plist)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("<!-- changed -->\n".utf8))
        try handle.close()
        let result = await SignatureVerifier(runner: runner).verifyApp(at: app, expecting: anyTeam)
        guard case .invalid(.brokenSignature(let detail)) = result else {
            Issue.record("expected brokenSignature, got \(result)")
            return
        }
        #expect(!detail.isEmpty)
    }

    @Test func unsignedPackageIsUnsigned() async throws {
        let (root, _) = try makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("hello\n".utf8).write(to: payload.appendingPathComponent("hello.txt"))
        let package = root.appendingPathComponent("Tiny.pkg")
        let build = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pkgbuild"),
            arguments: ["--root", payload.path, "--identifier", "dev.settlein.tinypkg", "--version", "1", package.path])
        #expect(build.exitCode == 0, "pkgbuild failed: \(build.stderr)")
        let result = await SignatureVerifier(runner: runner).verifyPackage(at: package, expecting: anyTeam)
        #expect(result == .invalid(.unsigned))
    }
}
