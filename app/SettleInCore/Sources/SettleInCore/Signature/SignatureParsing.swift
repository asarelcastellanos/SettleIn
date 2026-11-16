import Foundation

/// What `pkgutil --check-signature` says about a package.
public enum PackageSignature: Equatable, Sendable {
    /// The status is `no signature`.
    case unsigned
    /// The status names a certificate that macOS trusts. `teamID` comes from the `Developer ID Installer`
    /// certificate line, and it is nil when the output has no such line.
    case trusted(teamID: String?)
    /// The output has one status line, and the status is neither `no signature` nor a trusted one.
    case untrusted(status: String)
    /// The output has no status line or more than one.
    case unrecognized
}

extension SignatureVerifier {
    static let trustedPackageStatus = "signed by a developer certificate issued by Apple for distribution"

    /// Reads the Team ID from the output of `codesign -dv --verbose=4`. Returns nil when the output has
    /// no `TeamIdentifier=` line, has more than one, or reports `not set`. The result is not checked
    /// against the catalog, and a lowercase value comes back as written.
    public static func parseTeamIdentifier(codesignOutput: String) -> String? {
        let prefix = "TeamIdentifier="
        let values = lines(of: codesignOutput).filter { $0.hasPrefix(prefix) }
        guard values.count == 1, let line = values.first else { return nil }
        let value = String(line.dropFirst(prefix.count))
        return isPlausibleTeamIdentifier(value) ? value : nil
    }

    /// Reads the output of `pkgutil --check-signature`.
    public static func parsePackageSignature(pkgutilOutput: String) -> PackageSignature {
        let trimmed = lines(of: pkgutilOutput).map { $0.trimmingCharacters(in: .whitespaces) }
        let statusPrefix = "Status:"
        let statuses = trimmed.filter { $0.hasPrefix(statusPrefix) }
        guard statuses.count == 1, let line = statuses.first else { return .unrecognized }
        let status = line.dropFirst(statusPrefix.count).trimmingCharacters(in: .whitespaces)
        if status == "no signature" { return .unsigned }
        if status == trustedPackageStatus { return .trusted(teamID: installerTeamIdentifier(in: trimmed)) }
        return .untrusted(status: status)
    }

    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The Team ID in the first certificate of the chain, such as `1. Developer ID Installer: Name (TEAMID)`.
    /// A second matching line makes the output ambiguous, so the result is nil.
    private static func installerTeamIdentifier(in trimmedLines: [String]) -> String? {
        let prefix = "1. Developer ID Installer:"
        let matches = trimmedLines.filter { $0.hasPrefix(prefix) }
        guard matches.count == 1, let line = matches.first, line.hasSuffix(")"),
              let open = line.lastIndex(of: "(")
        else { return nil }
        let value = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
        return isPlausibleTeamIdentifier(value) ? value : nil
    }

    /// Letters and digits only, so a value such as `not set` is not a Team ID. The check allows lowercase
    /// letters so a wrong-case value reaches the exact comparison and fails as a mismatch.
    private static func isPlausibleTeamIdentifier(_ value: String) -> Bool {
        (1...32).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A)
        }
    }
}
