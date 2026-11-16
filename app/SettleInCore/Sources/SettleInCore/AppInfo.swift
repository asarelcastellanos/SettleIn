import Foundation

public enum AppInfo {
    public static let name = "SettleIn"

    /// Returns text like "0.1.0 (1)", or "unknown" when either version key is missing or not a string.
    public static func versionString(infoDictionary: [String: Any]?) -> String {
        guard
            let version = infoDictionary?["CFBundleShortVersionString"] as? String,
            let build = infoDictionary?["CFBundleVersion"] as? String
        else {
            return "unknown"
        }
        return "\(version) (\(build))"
    }
}
