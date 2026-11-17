import Foundation
import Testing
@testable import SettleInCore

private func digest(_ character: Character) -> SHA256Digest {
    guard let value = SHA256Digest(String(repeating: character, count: 64)) else { fatalError("bad literal") }
    return value
}

private let signatureFailures: [SignatureFailure] = [
    .unsigned,
    .brokenSignature(detail: "HOSTILE-DETAIL"),
    .gatekeeperRejected(detail: "HOSTILE-DETAIL"),
    .teamIDMissing,
    .teamIDMismatch(expected: "EQHXZ8M8AV", actual: "ABCDEFGHIJ"),
    .toolFailed(tool: "codesign", exitCode: 2),
    .toolFailed(tool: "spctl", exitCode: SignatureFailure.toolDidNotStart)
]

/// One value of every case of every error that `InstallFailure` wraps.
private let everyFailure: [InstallFailure] = {
    var all: [InstallFailure] = [
        .download(.insecureScheme),
        .download(.disallowedHost("evil.example")),
        .download(.disallowedRedirect("evil.example")),
        .download(.unexpectedStatus(404)),
        .download(.digestMismatch(expected: digest("a"), actual: digest("b"))),
        .download(.transferFailed(code: -1009)),
        .download(.fileWriteFailed),
        .download(.privateDirectoryFailed(reason: "HOSTILE-DETAIL")),
        .install(.destinationNotWritable(path: "/Applications")),
        .install(.workingDirectoryFailed),
        .install(.mountTimedOut),
        .install(.mountFailed(detail: "HOSTILE-DETAIL")),
        .install(.extractFailed(detail: "HOSTILE-DETAIL")),
        .install(.unsafeArchiveItem(path: "HOSTILE-DETAIL")),
        .install(.appNotFound(name: "Fixture.app")),
        .install(.freeSpaceUnreadable(path: "/Applications")),
        .install(.notEnoughSpace(needed: 2_000_000_000, available: 1_000_000)),
        .install(.bundleIDMismatch(expected: "com.example.Fixture")),
        .install(.differentAppAtDestination(path: "/Applications/Fixture.app")),
        .install(.replaceDeclined),
        .install(.quitDeclined),
        .install(.appStillRunning),
        .install(.copyFailed(detail: "HOSTILE-DETAIL")),
        .package(.alreadyInstalled),
        .package(.notAPackageEntry),
        .package(.installerDidNotOpen),
        .package(.timedOut),
        .uninstall(.quitDeclined),
        .uninstall(.appStillRunning),
        .stillPresentAfterUninstall,
        .uninstallIncomplete(leftAlone: 1),
        .uninstallIncomplete(leftAlone: 3),
        .interrupted,
        .unexpected
    ]
    all += signatureFailures.map { .install(.signatureInvalid($0)) }
    all += signatureFailures.map { .package(.signature($0)) }
    return all
}()

extension InstallStateTests {
    struct FailureMessages {
        @Test(arguments: everyFailure)
        func everyFailureHasOneNonEmptySentence(_ failure: InstallFailure) {
            let message = failure.userMessage
            #expect(!message.isEmpty)
            #expect(message.hasSuffix("."))
        }

        @Test(arguments: everyFailure)
        func noMessageRepeatsToolOutputOrArchiveText(_ failure: InstallFailure) {
            #expect(!failure.userMessage.contains("HOSTILE-DETAIL"))
        }

        @Test func aToolFailureNamesTheToolAndItsExitCode() {
            let failure = InstallFailure.install(.signatureInvalid(.toolFailed(tool: "codesign", exitCode: 2)))
            let message = failure.userMessage
            #expect(message.contains("codesign"))
            #expect(message.contains("exit code 2"))
        }

        @Test func aToolFailureExposesItsToolExit() throws {
            let failure = InstallFailure.package(.signature(.toolFailed(tool: "pkgutil", exitCode: 5)))
            let exit = try #require(failure.toolExit)
            #expect(exit.tool == "pkgutil")
            #expect(exit.exitCode == 5)
            #expect(InstallFailure.interrupted.toolExit == nil)
        }

        @Test func theStillPresentMessageSaysWhatHappenedAndWhatToDo() {
            let message = InstallFailure.stillPresentAfterUninstall.userMessage
            #expect(message.contains("removed what the catalog lists"))
            #expect(message.contains("still found the app"))
            #expect(message.contains("by hand"))
        }

        @Test func engineErrorsMapToTheirOwnCase() {
            #expect(InstallFailure.from(DownloadError.insecureScheme) == .download(.insecureScheme))
            #expect(InstallFailure.from(InstallError.replaceDeclined) == .install(.replaceDeclined))
            #expect(InstallFailure.from(UninstallError.appStillRunning) == .uninstall(.appStillRunning))
            #expect(InstallFailure.from(CocoaError(.fileNoSuchFile)) == .unexpected)
        }
    }
}
