import SettleInCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppListModel
    private let version = AppInfo.versionString(infoDictionary: Bundle.main.infoDictionary)

    var body: some View {
        VStack(spacing: 0) {
            switch model.catalog {
            case .loaded(let apps):
                List(apps, id: \.id) { app in
                    AppRowView(
                        app: app,
                        state: model.state(of: app),
                        onInstall: { model.install(app) },
                        onUninstall: { model.uninstall(app) },
                        onCancel: { model.cancel(app) },
                        onCopyLog: { model.copyLog(of: app) }
                    )
                }
            case .failed(let message):
                List {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SettleIn could not read its catalog")
                            .font(.headline)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
            Text("\(AppInfo.name) \(version)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}

#Preview {
    ContentView(model: AppListModel())
}
