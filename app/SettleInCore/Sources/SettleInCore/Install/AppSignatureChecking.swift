import Foundation

/// The signature check that `AppInstaller` runs on its staged copy. Tests supply a stub, because an ad hoc
/// signed test app has no Team ID.
public protocol AppSignatureChecking: Sendable {
    func verifyApp(at app: URL, expecting expected: TeamID) async -> SignatureResult
}

extension SignatureVerifier: AppSignatureChecking {}
