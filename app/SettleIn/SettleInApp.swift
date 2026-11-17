import SwiftUI
import SettleInCore

@main
struct SettleInApp: App {
    @StateObject private var model = AppListModel()

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
