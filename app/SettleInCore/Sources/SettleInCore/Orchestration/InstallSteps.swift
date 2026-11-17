import Foundation

// The orchestrator talks to the engine through these protocols. Each real engine type conforms in this
// file, and tests pass fakes. None of the conformances changes the engine type.

/// Downloads a catalog file and runs `body` while the file exists.
public protocol AppDownloading: Sendable {
    /// Calls `body` with the local file after the digest check. The file is gone when this returns or throws.
    /// Cancelling the task throws `CancellationError` and removes the file.
    func download(
        source: CatalogDownload,
        allowedHosts: [AllowedHost],
        progress: @escaping @Sendable (DownloadProgress) -> Void,
        body: (URL) async throws -> Void
    ) async throws -> DownloadIntegrity
}

/// Installs an app from a dmg or zip. The installer checks the signature of its staged copy.
public protocol AppInstalling: Sendable {
    @discardableResult
    func install(archive: URL, kind: InstallKind, app: InstallTarget) async throws -> URL

    /// Installs like `install(archive:kind:app:)` and passes notes about the cleanup to `report`.
    @discardableResult
    func install(archive: URL, kind: InstallKind, app: InstallTarget, report: InstallReport?) async throws -> URL
}

extension AppInstalling {
    /// An installer that has nothing to report ignores the closure.
    @discardableResult
    public func install(
        archive: URL,
        kind: InstallKind,
        app: InstallTarget,
        report: InstallReport?
    ) async throws -> URL {
        try await install(archive: archive, kind: kind, app: app)
    }
}

/// Installs a pkg through Installer.app. The installer checks the package signature first.
public protocol PackageInstalling: Sendable {
    func install(package: URL, app: CatalogApp) -> AsyncStream<PackageInstallState>
}

/// Removes an app and the paths its catalog entry lists.
public protocol AppUninstalling: Sendable {
    func uninstall(app: CatalogApp) async throws -> UninstallReport
}

extension Downloader: AppDownloading {
    public func download(
        source: CatalogDownload,
        allowedHosts: [AllowedHost],
        progress: @escaping @Sendable (DownloadProgress) -> Void,
        body: (URL) async throws -> Void
    ) async throws -> DownloadIntegrity {
        try await withDownload(source: source, allowedHosts: allowedHosts, progress: progress, body: body).integrity
    }
}

extension AppInstaller: AppInstalling {}
extension PackageInstaller: PackageInstalling {}
extension Uninstaller: AppUninstalling {}

extension DownloadProgress {
    /// The fraction received, or `nil` when the server announced no size.
    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}
