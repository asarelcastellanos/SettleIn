import SwiftUI
import SettleInCore

@main
struct SettleInApp: App {
    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
