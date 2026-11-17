import Foundation

/// A timestamped record of one operation, such as the steps, the tools that failed with their exit
/// codes, and each state change. The app holds no secrets, so the log holds none.
///
/// The log replaces the home directory with `~` in every line, so a copied log does not show the user
/// name. It replaces the home folder only at a path boundary. A line holds no line break, so text from outside
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

    /// Replaces `home` only where a "/" or the end of the text follows it, so `/Users/al` does not match
    /// the start of `/Users/alice`.
    private static func replacing(_ home: String, with tilde: String, in text: String) -> String {
        var result = ""
        var rest = text[...]
        while let match = rest.range(of: home) {
            result += rest[..<match.lowerBound]
            let after = rest[match.upperBound...]
            let atBoundary = after.isEmpty || after.unicodeScalars.first == "/"
            result += atBoundary ? tilde : home
            rest = after
        }
        return result + rest
    }
}
