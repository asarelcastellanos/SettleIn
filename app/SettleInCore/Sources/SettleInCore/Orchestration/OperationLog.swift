import Foundation

/// A timestamped record of one operation, such as the steps, the tools that failed with their exit
/// codes, and each state change. The app holds no secrets, so the log holds none.
///
/// The log replaces the home directory with `~` in every line, so a copied log does not show the user
/// name. It replaces the home folder only where it stands alone as a path. A line holds no line break, so text from outside
/// cannot forge a second line.
public struct OperationLog: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let timestamp: Date
        public let text: String
    }

    public private(set) var entries: [Entry] = []
    private let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    public mutating func append(_ text: String, at timestamp: Date) {
        entries.append(Entry(timestamp: timestamp, text: sanitized(text)))
    }

    /// One line per entry, such as `2026-11-16T09:30:00Z install requested for rectangle`.
    public var text: String {
        entries
            .map { "\($0.timestamp.formatted(.iso8601)) \($0.text)" }
            .joined(separator: "\n")
    }

    private func sanitized(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        // A home of "/" or "" would match every path, so the log never replaces it.
        guard homeDirectory.count > 1 else { return oneLine }
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        return Self.replacing(home, with: "~", in: oneLine)
    }

    /// Replaces `home` only where it stands alone as a path. The character before it must not be part of a path
    /// name (a letter, a digit, or one of `._/-`), or the home folder starts the text. The character after it
    /// must not be a letter, a digit, or one of `._-`. So `(/Users/al)` and `/Users/al: x` change, while
    /// `/Users/alice/x` and `/tmp/Users/al/foo` stay as written.
    private static func replacing(_ home: String, with tilde: String, in text: String) -> String {
        var result = ""
        var copied = text.startIndex
        var searchFrom = text.startIndex
        while let match = text.range(of: home, range: searchFrom..<text.endIndex) {
            searchFrom = match.upperBound
            let before = text[..<match.lowerBound].unicodeScalars.last
            let after = text[match.upperBound...].unicodeScalars.first
            let startsPath = before.map { !isNameCharacter($0, extra: "._/-") } ?? true
            let endsPath = after.map { !isNameCharacter($0, extra: "._-") } ?? true
            guard startsPath, endsPath else { continue }
            result += text[copied..<match.lowerBound] + tilde
            copied = match.upperBound
        }
        return result + text[copied...]
    }

    private static func isNameCharacter(_ scalar: Unicode.Scalar, extra: String) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || extra.unicodeScalars.contains(scalar)
    }
}
