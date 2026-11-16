import Testing
@testable import SettleInCore

struct AppInfoTests {
    @Test func nameIsSettleIn() {
        #expect(AppInfo.name == "SettleIn")
    }

    @Test func versionStringJoinsVersionAndBuild() {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1"
        ]
        #expect(AppInfo.versionString(infoDictionary: info) == "0.1.0 (1)")
    }

    @Test func versionStringIsUnknownWhenBuildIsMissing() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0"]
        #expect(AppInfo.versionString(infoDictionary: info) == "unknown")
    }

    @Test func versionStringIsUnknownWhenVersionIsMissing() {
        let info: [String: Any] = ["CFBundleVersion": "1"]
        #expect(AppInfo.versionString(infoDictionary: info) == "unknown")
    }

    @Test func versionStringIsUnknownWhenBothKeysAreMissing() {
        #expect(AppInfo.versionString(infoDictionary: [:]) == "unknown")
    }

    @Test func versionStringIsUnknownForNilDictionary() {
        #expect(AppInfo.versionString(infoDictionary: nil) == "unknown")
    }
}
