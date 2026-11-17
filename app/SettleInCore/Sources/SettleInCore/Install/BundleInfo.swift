import Foundation

/// Reads the identity of an app bundle from its `Info.plist`.
enum BundleInfo {
    /// The `CFBundleIdentifier` of the bundle at `app`. Returns nil when `app` is not a plain folder, when the
    /// plist is missing or unreadable, and when the value is not a string. A symbolic link is not a folder here.
    static func identifier(ofAppAt app: URL) -> String? {
        let type = try? FileManager.default.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType
        guard
            type == .typeDirectory,
            let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
}
