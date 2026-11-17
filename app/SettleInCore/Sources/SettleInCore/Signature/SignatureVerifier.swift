import Foundation

/// Decides whether an app or package carries a valid signature from the vendor the catalog names.
/// The Team ID comes from the output of macOS tools only, never from a file name, a URL, or an Info.plist.
public struct SignatureVerifier: Sendable {
    private let runner: any CommandRunner

    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.runner = runner
    }

    private enum Tool {
        static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        static let spctl = URL(fileURLWithPath: "/usr/sbin/spctl")
        static let pkgutil = URL(fileURLWithPath: "/usr/sbin/pkgutil")
    }

    /// Runs three checks in order and stops at the first failure. `codesign --verify` checks the seal, then
    /// `codesign -dv` reads the Team ID, then `spctl` asks Gatekeeper. The Team ID check comes before
    /// `spctl` because Gatekeeper rejects every ad hoc signed app, and the Team ID check reports that case
    /// more precisely as `teamIDMissing`.
    public func verifyApp(at app: URL, expecting expected: TeamID) async -> SignatureResult {
        if let failure = await checkSeal(of: app) { return .invalid(failure) }
        if let failure = await checkTeamID(of: app, expecting: expected) { return .invalid(failure) }
        if let failure = await checkGatekeeper(for: app) { return .invalid(failure) }
        return .valid(expected)
    }

    private func checkSeal(of app: URL) async -> SignatureFailure? {
        switch await execute(Tool.codesign, ["--verify", "--deep", "--strict", "--verbose=2", app.path]) {
        case .failure(let failure): return failure
        case .success(let result): return result.exitCode == 0 ? nil : Self.verifyFailure(result)
        }
    }

    private func checkTeamID(of app: URL, expecting expected: TeamID) async -> SignatureFailure? {
        switch await execute(Tool.codesign, ["-dv", "--verbose=4", app.path]) {
        case .failure(let failure):
            return failure
        case .success(let result) where result.exitCode != 0:
            return Self.toolFailure(Tool.codesign, result)
        case .success(let result):
            let actual = Self.parseTeamIdentifier(codesignOutput: result.combinedOutput)
            if case .invalid(let failure) = Self.compare(actual: actual, expected: expected) { return failure }
            return nil
        }
    }

    /// `spctl` exits with 3 when it rejects the app. Any other nonzero code means the tool failed.
    private func checkGatekeeper(for app: URL) async -> SignatureFailure? {
        switch await execute(Tool.spctl, ["--assess", "--type", "execute", "--verbose=4", app.path]) {
        case .failure(let failure): return failure
        case .success(let result) where result.exitCode == 0: return nil
        case .success(let result) where result.exitCode == 3:
            return .gatekeeperRejected(detail: Self.detail(of: result.combinedOutput))
        case .success(let result): return Self.toolFailure(Tool.spctl, result)
        }
    }

    /// Runs `pkgutil --check-signature`. A package passes only with exit code 0, a trusted status, and a
    /// `Developer ID Installer` certificate that carries the expected Team ID.
    public func verifyPackage(at package: URL, expecting expected: TeamID) async -> SignatureResult {
        let result: CommandResult
        switch await execute(Tool.pkgutil, ["--check-signature", package.path]) {
        case .failure(let failure): return .invalid(failure)
        case .success(let value): result = value
        }

        let signature = Self.parsePackageSignature(pkgutilOutput: result.combinedOutput)
        switch signature {
        case .unsigned:
            return .invalid(.unsigned)
        case .untrusted(let status):
            return .invalid(.brokenSignature(detail: status))
        case .unrecognized:
            return .invalid(result.exitCode == 0
                ? .brokenSignature(detail: "pkgutil did not report a signature status.")
                : Self.toolFailure(Tool.pkgutil, result))
        case .trusted(let actual):
            if result.exitCode != 0 { return .invalid(Self.toolFailure(Tool.pkgutil, result)) }
            return Self.compare(actual: actual, expected: expected)
        }
    }

    // MARK: Helpers

    private func execute(_ tool: URL, _ arguments: [String]) async -> Result<CommandResult, SignatureFailure> {
        do {
            return .success(try await runner.run(executable: tool, arguments: arguments))
        } catch {
            return .failure(.toolFailed(tool: tool.lastPathComponent, exitCode: SignatureFailure.toolDidNotStart))
        }
    }

    /// Exact, case-sensitive comparison. A missing Team ID is its own failure.
    private static func compare(actual: String?, expected: TeamID) -> SignatureResult {
        guard let actual else { return .invalid(.teamIDMissing) }
        guard actual == expected.rawValue else {
            return .invalid(.teamIDMismatch(expected: expected.rawValue, actual: actual))
        }
        return .valid(expected)
    }

    /// `codesign --verify` exits with 1 for a signature that fails the check. Any other code means the tool failed.
    private static func verifyFailure(_ result: CommandResult) -> SignatureFailure {
        guard result.exitCode == 1 else { return toolFailure(Tool.codesign, result) }
        if result.combinedOutput.contains("code object is not signed at all") { return .unsigned }
        return .brokenSignature(detail: detail(of: result.combinedOutput))
    }

    private static func toolFailure(_ tool: URL, _ result: CommandResult) -> SignatureFailure {
        .toolFailed(tool: tool.lastPathComponent, exitCode: result.exitCode)
    }

    /// Keeps the message lines of tool output. `codesign --verbose=2` prints one progress line per nested file,
    /// and the message is at the end. The text is capped so one failure cannot fill the UI.
    private static func detail(of output: String) -> String {
        let message = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--prepared:") && !$0.hasPrefix("--validated:") }
            .joined(separator: " ")
        return message.count > 500 ? String(message.prefix(500)) + "..." : message
    }
}
