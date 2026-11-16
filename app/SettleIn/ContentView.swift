import SwiftUI
import SettleInCore

struct ContentView: View {
    private let version = AppInfo.versionString(infoDictionary: Bundle.main.infoDictionary)

    var body: some View {
        VStack(spacing: 8) {
            Text(AppInfo.name)
                .font(.largeTitle)
            Text(version)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 280, minHeight: 160)
    }
}

#Preview {
    ContentView()
}
