import Foundation

private func isASCIIUppercase(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x41 && scalar.value <= 0x5A }
private func isASCIILowercase(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x61 && scalar.value <= 0x7A }
private func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }

/// True for a dotted name with at least two labels, each made of letters, digits, and hyphens.
private func isReverseDNSName(_ raw: String) -> Bool {
    let labels = raw.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    return labels.allSatisfy { label in
        !label.isEmpty && label.unicodeScalars.allSatisfy {
            isASCIIUppercase($0) || isASCIILowercase($0) || isASCIIDigit($0) || $0 == "-"
        }
    }
}

/// An Apple Team ID, 10 uppercase letters or digits.
public struct TeamID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    init?(_ raw: String) {
        let scalars = raw.unicodeScalars
        guard scalars.count == 10, scalars.allSatisfy({ isASCIIUppercase($0) || isASCIIDigit($0) }) else {
            return nil
        }
        rawValue = raw
    }
}

/// An app's bundle identifier, such as `com.example.App`.
public struct BundleID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    init?(_ raw: String) {
        guard isReverseDNSName(raw) else { return nil }
        rawValue = raw
    }
}

/// The identifier that `pkgutil` reports for a package.
public struct PackageIdentifier: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    init?(_ raw: String) {
        guard isReverseDNSName(raw) else { return nil }
        rawValue = raw
    }
}

/// The `.app` folder name inside a dmg or zip. It holds no path separator.
public struct AppBundleName: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    init?(_ raw: String) {
        guard raw.hasSuffix(".app"), raw.count > ".app".count,
              !raw.contains("/"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        rawValue = raw
    }
}

/// A SHA-256 digest, 64 hex characters. The value is stored in lowercase.
public struct SHA256Digest: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    init?(_ raw: String) {
        let scalars = raw.unicodeScalars
        guard scalars.count == 64, scalars.allSatisfy({ $0.properties.isASCIIHexDigit }) else { return nil }
        rawValue = raw.lowercased()
    }
}

/// A lowercase host name that a download may use, such as `github.com`.
public struct AllowedHost: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    init?(_ raw: String) {
        let labels = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(Self.isValidLabel) else { return nil }
        rawValue = raw
    }

    private static func isValidLabel(_ label: Substring) -> Bool {
        guard (1...63).contains(label.count), label.first != "-", label.last != "-" else { return false }
        return label.unicodeScalars.allSatisfy { isASCIILowercase($0) || isASCIIDigit($0) || $0 == "-" }
    }

    func matches(_ url: URL) -> Bool {
        url.host(percentEncoded: false)?.lowercased() == rawValue
    }
}

/// A path that the uninstaller may remove. It starts with `/Applications/`, `~/Library/`, or `~/.config/`.
/// This type checks the catalog text only. It does not touch the file system.
public struct UninstallPath: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    init(_ raw: String) throws {
        let scalars = raw.unicodeScalars
        let wildcards = "*?[]{}".unicodeScalars
        if scalars.contains(where: { wildcards.contains($0) }) { throw UninstallPathRule.containsWildcard }
        let components = raw.split(separator: "/", omittingEmptySubsequences: false)
        if components.contains("..") { throw UninstallPathRule.containsParentTraversal }

        let roots = ["/Applications", "~/Library", "~/.config"]
        if roots.contains(raw) { throw UninstallPathRule.isRoot }
        guard let root = roots.first(where: { raw.hasPrefix($0 + "/") }) else {
            throw UninstallPathRule.outsideAllowedRoots
        }

        let relative = raw.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        let hasControl = scalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        if hasControl || relative.contains(where: { $0.isEmpty || $0 == "." }) { throw UninstallPathRule.malformed }
        if root == "~/Library", relative.count < 2 { throw UninstallPathRule.directChildOfLibrary }
        rawValue = raw
    }
}
