import Foundation

/// Removes an installed app and the support files its catalog entry lists, and nothing else.
///
/// Every path goes through `PathGuard` right before its removal, even though the catalog parser checked the
/// text earlier. Removal moves the item to the Trash. Only when the Trash fails does the uninstaller delete
/// the same approved path for good. Any approved path that ends in `.app` must hold a bundle whose
/// identifier equals the catalog bundle ID, so an entry cannot remove another app. This file is the only one in the package that deletes files. The
/// uninstaller never forces an app to quit.
public struct Uninstaller: Sendable {
    let pathGuard: PathGuard
    let runningApps: any RunningAppProviding
    let quitTimeout: Duration
    let trash: @Sendable (ApprovedPath) throws -> Void
    let confirmQuit: @Sendable (CatalogApp) async -> Bool

    /// - Parameters:
    ///   - roots: The allowed folders. Tests pass folders inside a temporary directory.
    ///   - trash: Moves an approved path to the Trash. Tests replace it to stay out of the real Trash.
    ///   - confirmQuit: Asked when the app is running. After a yes, the uninstaller asks the app to quit.
    public init(
        roots: AllowedRoots = .system,
        runningApps: any RunningAppProviding = WorkspaceRunningApps(),
        quitTimeout: Duration = .seconds(10),
        trash: @escaping @Sendable (ApprovedPath) throws -> Void = Uninstaller.moveToTrash,
        confirmQuit: @escaping @Sendable (CatalogApp) async -> Bool
    ) {
        self.pathGuard = PathGuard(roots: roots)
        self.runningApps = runningApps
        self.quitTimeout = quitTimeout
        self.trash = trash
        self.confirmQuit = confirmQuit
    }

    @Sendable public static func moveToTrash(_ path: ApprovedPath) throws {
        try FileManager.default.trashItem(at: path.url, resultingItemURL: nil)
    }

    /// Removes the app and then each catalog path. A `.pkg` entry has no app bundle name, so it has only
    /// the catalog paths. When a different app sits at the app's own path, nothing is removed at all. A listed
    /// path that ends in `.app` and holds another bundle is refused, and the other paths go on.
    public func uninstall(app: CatalogApp) async throws -> UninstallReport {
        let appPath = appPathText(of: app)
        if let appPath, case .mismatch(let reason) = vet(appPath, bundleID: app.bundleID) {
            let others = app.uninstallPaths.map {
                UninstallItem(path: $0.rawValue, outcome: .refused(reason: "left alone because \(reason)"))
            }
            return UninstallReport(items: [UninstallItem(path: appPath, outcome: .refused(reason: reason))] + others)
        }
        try await quitIfRunning(app)

        var items: [UninstallItem] = []
        if let appPath {
            items.append(UninstallItem(path: appPath, outcome: remove(appPath, bundleID: app.bundleID)))
        }
        for path in app.uninstallPaths {
            items.append(UninstallItem(path: path.rawValue, outcome: remove(path.rawValue, bundleID: app.bundleID)))
        }
        return UninstallReport(items: items)
    }

    // MARK: Quit

    private func quitIfRunning(_ app: CatalogApp) async throws {
        guard runningApps.isRunning(bundleID: app.bundleID) else { return }
        guard await confirmQuit(app) else { throw UninstallError.appStillRunning }
        guard await runningApps.terminate(bundleID: app.bundleID, timeout: quitTimeout),
              !runningApps.isRunning(bundleID: app.bundleID)
        else { throw UninstallError.appStillRunning }
    }

    // MARK: Removal

    private enum Vetting {
        case ready(ApprovedPath)
        case absent
        case refused(String)
        case mismatch(String)
    }

    private func appPathText(of app: CatalogApp) -> String? {
        guard let target = InstallTarget(catalogApp: app) else { return nil }
        return pathGuard.roots.applications.appendingPathComponent(target.appName.rawValue).path
    }

    /// Runs `PathGuard` on `text`, so every call re-resolves the path. When the path ends in `.app`, the
    /// bundle there must carry `bundleID`. A missing bundle or an unreadable `Info.plist` counts as a mismatch.
    private func vet(_ text: String, bundleID: BundleID) -> Vetting {
        let approved: ApprovedPath
        do {
            approved = try pathGuard.approve(text)
        } catch {
            return .refused(error.description)
        }
        guard FileManager.default.fileExists(atPath: approved.url.path) else { return .absent }
        if approved.url.lastPathComponent.lowercased().hasSuffix(".app"), !carries(bundleID, at: approved.url) {
            return .mismatch("a different app is at \(text), so SettleIn left it alone")
        }
        return .ready(approved)
    }

    private func remove(_ text: String, bundleID: BundleID) -> UninstallOutcome {
        let approved: ApprovedPath
        switch vet(text, bundleID: bundleID) {
        case .ready(let path): approved = path
        case .absent: return .skipped
        case .refused(let reason), .mismatch(let reason): return .refused(reason: reason)
        }
        do {
            try trash(approved)
            return .trashed
        } catch {
            return deleteInstead(text, bundleID: bundleID, previously: approved)
        }
    }

    /// Runs after the Trash failed. The path goes through `PathGuard` again, and it must resolve to the
    /// same place as before.
    private func deleteInstead(
        _ text: String,
        bundleID: BundleID,
        previously: ApprovedPath
    ) -> UninstallOutcome {
        let approved: ApprovedPath
        switch vet(text, bundleID: bundleID) {
        case .ready(let path): approved = path
        case .absent: return .skipped
        case .refused(let reason), .mismatch(let reason): return .refused(reason: reason)
        }
        guard approved == previously else {
            return .refused(reason: "the path changed while SettleIn worked, so SettleIn left it alone")
        }
        do {
            try FileManager.default.removeItem(at: approved.url)
            return .deleted
        } catch {
            return .refused(reason: "the Trash and a direct delete both failed for \(text)")
        }
    }

    private func carries(_ bundleID: BundleID, at app: URL) -> Bool {
        let type = try? FileManager.default.attributesOfItem(atPath: app.path)[.type] as? FileAttributeType
        guard
            type == .typeDirectory,
            let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return info["CFBundleIdentifier"] as? String == bundleID.rawValue
    }
}
