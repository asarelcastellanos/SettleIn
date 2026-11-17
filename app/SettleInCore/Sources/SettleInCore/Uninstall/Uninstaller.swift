import Foundation

/// Removes an installed app and the support files its catalog entry lists, and nothing else.
///
/// Every path goes through `PathGuard` right before its removal, even though the catalog parser checked the
/// text earlier. Removal moves the item to the Trash. Only when the Trash fails does the uninstaller delete
/// the same approved path for good. Any approved path that ends in `.app` must hold a bundle whose
/// identifier equals the catalog bundle ID, so an entry cannot remove another app. This file is the only one in
/// the package that deletes files. The uninstaller never forces an app to quit.
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

    /// Removes the app and then each catalog path. For a dmg or zip entry the app is the bundle named by
    /// `appName` in the applications folder. A `.pkg` entry has no app bundle name, so its app items are the
    /// listed paths directly under `/Applications` that end in `.app`. Every other listed path is a support item.
    ///
    /// SettleIn checks every app item before it changes anything. When an app item holds another bundle or the
    /// path guard refuses it, nothing is removed and the app is not asked to quit. When the app is running,
    /// the user is asked first. After the app items, a removal that fails stops the run, so no support path is
    /// removed from an app that is still installed. Each path left alone is marked as refused with the reason.
    ///
    /// Before it removes any item, the uninstaller looks at the disk. When the path or a folder above it, up to
    /// the allowed folder, ends in `.app` and holds `Contents/Info.plist`, that folder is a real bundle and
    /// its identifier must be the catalog bundle ID. A support item inside another app is refused alone, and
    /// the other paths go on. A `.app` folder without `Contents/Info.plist` is a plain folder.
    public func uninstall(app: CatalogApp) async throws -> UninstallReport {
        let appTexts = appItemTexts(of: app)
        let otherTexts = otherTexts(of: app)
        for text in appTexts {
            switch vet(text, bundleID: app.bundleID, isAppItem: true) {
            case .mismatch(let reason), .refused(let reason):
                return refusedReport(appTexts + otherTexts, blaming: text, because: reason)
            case .ready, .absent:
                continue
            }
        }
        try await quitIfRunning(app)

        var items: [UninstallItem] = []
        var blocker: String?
        for text in appTexts {
            let outcome = remove(text, bundleID: app.bundleID, isAppItem: true)
            items.append(UninstallItem(path: text, outcome: outcome))
            if blocker == nil, case .refused(let reason) = outcome { blocker = reason }
        }
        for text in otherTexts {
            if let blocker {
                items.append(UninstallItem(path: text, outcome: .refused(
                    reason: "left alone because SettleIn did not remove the app (\(blocker))"
                )))
            } else {
                items.append(UninstallItem(path: text, outcome: remove(text, bundleID: app.bundleID, isAppItem: false)))
            }
        }
        return UninstallReport(items: items)
    }

    /// The app items first, in order, then the catalog paths. The blamed path keeps its own reason.
    private func refusedReport(_ texts: [String], blaming blamed: String, because reason: String) -> UninstallReport {
        var blameGiven = false
        let items = texts.map { text -> UninstallItem in
            if text == blamed, !blameGiven {
                blameGiven = true
                return UninstallItem(path: text, outcome: .refused(reason: reason))
            }
            return UninstallItem(path: text, outcome: .refused(reason: "left alone because \(reason)"))
        }
        return UninstallReport(items: items)
    }

    // MARK: Plan

    /// A dmg or zip entry has one app item, the bundle in the applications folder. A pkg entry has the listed
    /// paths directly under `/Applications` that end in `.app`.
    private func appItemTexts(of app: CatalogApp) -> [String] {
        if let appPath = appPathText(of: app) { return [appPath] }
        return app.uninstallPaths.filter(\.isApplicationsApp).map(\.rawValue)
    }

    /// The support items. A dmg or zip entry keeps all of its listed paths, including a repeat of its app path.
    private func otherTexts(of app: CatalogApp) -> [String] {
        let texts = app.uninstallPaths.map(\.rawValue)
        return appPathText(of: app) == nil ? texts.filter { !appItemTexts(of: app).contains($0) } : texts
    }

    // MARK: Quit

    private func quitIfRunning(_ app: CatalogApp) async throws {
        guard runningApps.isRunning(bundleID: app.bundleID) else { return }
        guard await confirmQuit(app) else { throw UninstallError.quitDeclined }
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

    /// Runs `PathGuard` on `text`, so every call re-resolves the path. An app item must hold a bundle that
    /// carries `bundleID`, and a missing `Info.plist` counts as a mismatch. Any other item is refused when it
    /// sits inside a real bundle of another app, or is one.
    private func vet(_ text: String, bundleID: BundleID, isAppItem: Bool) -> Vetting {
        let approved: ApprovedPath
        do {
            approved = try pathGuard.approve(text)
        } catch {
            return .refused(error.description)
        }
        guard FileManager.default.fileExists(atPath: approved.url.path) else { return .absent }
        let foreign = isAppItem
            ? BundleInfo.identifier(ofAppAt: approved.url) != bundleID.rawValue
            : holdsForeignBundle(approved.url, bundleID: bundleID)
        if foreign { return .mismatch("a different app is at \(text), so SettleIn left it alone") }
        return .ready(approved)
    }

    /// True when `url` or a folder above it, up to the allowed folder, is a real bundle of another app. A real
    /// bundle is a folder whose name ends in `.app` and that holds `Contents/Info.plist`.
    private func holdsForeignBundle(_ url: URL, bundleID: BundleID) -> Bool {
        let parts = PathResolution.components(of: url.path)
        let roots = [pathGuard.roots.applications, pathGuard.roots.library, pathGuard.roots.config]
        let rootDepths = roots
            .compactMap { PathResolution.resolve(PathResolution.components(of: $0.path)) }
            .filter { parts.starts(with: $0) }
            .map(\.count)
        guard let rootDepth = rootDepths.max() else { return false }
        for depth in stride(from: parts.count, to: rootDepth, by: -1) {
            guard UninstallPathShape.isAppName(parts[depth - 1]) else { continue }
            let bundle = URL(fileURLWithPath: "/" + parts[0..<depth].joined(separator: "/"), isDirectory: true)
            let plist = bundle.appendingPathComponent("Contents/Info.plist").path
            let isReal = FileManager.default.fileExists(atPath: plist)
            if isReal, BundleInfo.identifier(ofAppAt: bundle) != bundleID.rawValue { return true }
        }
        return false
    }

    private func remove(_ text: String, bundleID: BundleID, isAppItem: Bool) -> UninstallOutcome {
        let approved: ApprovedPath
        switch vet(text, bundleID: bundleID, isAppItem: isAppItem) {
        case .ready(let path): approved = path
        case .absent: return .skipped
        case .refused(let reason), .mismatch(let reason): return .refused(reason: reason)
        }
        do {
            try trash(approved)
            return .trashed
        } catch {
            return deleteInstead(text, bundleID: bundleID, isAppItem: isAppItem, previously: approved)
        }
    }

    /// Runs after the Trash failed. The path goes through `PathGuard` again, and it must resolve to the
    /// same place as before.
    private func deleteInstead(
        _ text: String,
        bundleID: BundleID,
        isAppItem: Bool,
        previously: ApprovedPath
    ) -> UninstallOutcome {
        let approved: ApprovedPath
        switch vet(text, bundleID: bundleID, isAppItem: isAppItem) {
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
}
