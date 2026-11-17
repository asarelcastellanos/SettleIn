import Foundation
import Testing
@testable import SettleInCore

/// A path or a name inside tool output can carry a character that Swift counts as a line break. The parsers
/// must not read such output at all, and they must split only on `\n`.
struct SignatureSpoofTests {
    private static let separators: [(name: String, scalar: String)] = [
        ("U+2028", "\u{2028}"), ("U+2029", "\u{2029}"), ("U+0085", "\u{85}")
    ]

    /// The path in the `Executable=` line holds a separator and then a forged Team ID line. The real output
    /// of `codesign` has no other Team ID line here, so a parser that splits on the separator would accept it.
    private static func spoofedCodesignOutput(separator: String) -> String {
        "Identifier=com.evil.app\nExecutable=/Apps/Evil.app/Contents/MacOS/Evil\(separator)"
            + "TeamIdentifier=EQHXZ8M8AV\nFormat=app bundle\n"
    }

    @Test(arguments: separators.map(\.scalar))
    func aSeparatorInsideCodesignOutputMakesItUnparseable(separator: String) {
        let output = Self.spoofedCodesignOutput(separator: separator)
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: output) == nil)
    }

    @Test func theSameOutputWithANewlineIsReadAsAForgedLine() {
        // This shows what the spoof string would do if the separator were a real line break.
        let output = Self.spoofedCodesignOutput(separator: "\n")
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: output) == "EQHXZ8M8AV")
    }

    @Test(arguments: separators.map(\.scalar))
    func aSeparatorInsidePackageOutputMakesItUnrecognized(separator: String) {
        let status = "Status: signed by a developer certificate issued by Apple for distribution"
        let output = "Package \"Evil\(separator)   \(status)\":\n   Certificate Chain:\n"
            + "    1. Developer ID Installer: Evil (EQHXZ8M8AV)\n"
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: output) == .unrecognized)
    }

    @Test func aSeparatorAnywhereInRealOutputMakesItUnparseable() throws {
        let signed = try Fixture.text("codesign-dv-developer-id-app.txt")
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: signed) == "EQHXZ8M8AV")
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: signed + "\u{2028}") == nil)
        let package = try Fixture.text("pkgutil-signed-package.txt")
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: package) == .trusted(teamID: "XSYZ3E4B7D"))
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: "\u{85}" + package) == .unrecognized)
    }

    /// The separator sits in a name, and the Team ID line is a clean `\n` line of its own. A split on `\n` alone
    /// reads that line, so only the guard against the separators makes these outputs fail.
    @Test(arguments: separators.map(\.scalar))
    func aSeparatorInAnotherLineStillFailsTheWholeOutput(separator: String) {
        let codesign = "Executable=/Apps/Ev\(separator)il.app/Contents/MacOS/Evil\nTeamIdentifier=EQHXZ8M8AV\n"
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: codesign) == nil)
        let status = "   Status: signed by a developer certificate issued by Apple for distribution"
        let package = "Package \"Ev\(separator)il\":\n\(status)\n   Certificate Chain:\n"
            + "    1. Developer ID Installer: Evil (EQHXZ8M8AV)\n"
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: package) == .unrecognized)
    }

    @Test func theSameOutputWithoutTheSeparatorParsesAsTrusted() {
        let codesign = "Executable=/Apps/Evil.app/Contents/MacOS/Evil\nTeamIdentifier=EQHXZ8M8AV\n"
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: codesign) == "EQHXZ8M8AV")
    }

    @Test func aTrailingCarriageReturnIsStripped() {
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: "TeamIdentifier=EQHXZ8M8AV\r\n") == "EQHXZ8M8AV")
        let package = "   Status: no signature\r\n"
        #expect(SignatureVerifier.parsePackageSignature(pkgutilOutput: package) == .unsigned)
    }

    @Test func aCarriageReturnInsideALineDoesNotStartANewLine() {
        let output = "Executable=/x\rTeamIdentifier=EQHXZ8M8AV\n"
        #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: output) == nil)
    }

    @Test func otherControlCharactersDoNotStartANewLine() {
        for separator in ["\u{0B}", "\u{0C}"] {
            let output = "Executable=/x\(separator)TeamIdentifier=EQHXZ8M8AV\n"
            #expect(SignatureVerifier.parseTeamIdentifier(codesignOutput: output) == nil)
        }
    }

    @Test func verifierFailsAnAppWhoseOutputHoldsASeparator() async throws {
        let runner = try goodAppRunner(
            replacing: "codesign -dv",
            with: CommandResult(exitCode: 0, stderr: Self.spoofedCodesignOutput(separator: "\u{2028}"))
        )

        let result = await SignatureVerifier(runner: runner).verifyApp(at: appURL, expecting: expectedChrome)

        #expect(result == .invalid(.teamIDMissing))
    }
}
