import AppKit
import SettleInCore
import SwiftUI

/// What the launch read from the bundled catalog.
enum CatalogLoad {
    case loaded([CatalogApp])
    case failed(String)
}

/// Holds the catalog and each app's state for the window. All logic lives in `SettleInCore`.
@MainActor
final class AppListModel: ObservableObject {
    @Published private(set) var catalog: CatalogLoad
    @Published private(set) var states: [String: InstallState] = [:]

    private let orchestrator: InstallOrchestrator
    private var observer: Task<Void, Never>?

    init() {
        let catalog = Self.loadBundledCatalog()
        self.catalog = catalog
        orchestrator = InstallOrchestrator(
            appInstaller: AppInstaller(
                confirmReplace: { target in
                    await Confirmation.ask(
                        title: "Replace \(target.appName.rawValue)?",
                        detail: "A copy is already in Applications. SettleIn replaces it with the download.",
                        confirm: "Replace"
                    )
                },
                confirmQuit: { target in
                    await Confirmation.ask(
                        title: "Quit \(target.appName.rawValue)?",
                        detail: "The app is running. SettleIn asks it to quit before it replaces the app.",
                        confirm: "Quit and replace"
                    )
                }
            ),
            uninstaller: Uninstaller(
                confirmQuit: { app in
                    await Confirmation.ask(
                        title: "Quit \(app.name)?",
                        detail: "The app is running. SettleIn asks it to quit before it removes the app.",
                        confirm: "Quit and remove"
                    )
                }
            )
        )
        guard case .loaded(let apps) = catalog else { return }
        let changes = orchestrator.stateChanges
        observer = Task { [weak self, orchestrator] in
            await orchestrator.detectInstalled(in: apps)
            for await change in changes {
                self?.states[change.appID] = change.state
            }
        }
    }

    /// Reads `catalog.json` from the app bundle. This is the only catalog the app reads.
    private static func loadBundledCatalog() -> CatalogLoad {
        guard
            let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            return .failed("The app bundle does not contain catalog.json.")
        }
        do {
            return .loaded(try CatalogParser.parse(data).apps)
        } catch {
            return .failed("The bundled catalog is not valid. \(error)")
        }
    }

    func state(of app: CatalogApp) -> InstallState {
        states[app.id] ?? .idle
    }

    func install(_ app: CatalogApp) {
        Task { await orchestrator.install(app) }
    }

    func uninstall(_ app: CatalogApp) {
        Task { await orchestrator.uninstall(app) }
    }

    func cancel(_ app: CatalogApp) {
        Task { await orchestrator.cancel(appID: app.id) }
    }

    func copyLog(of app: CatalogApp) {
        Task {
            let text = await orchestrator.log(for: app.id).text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
