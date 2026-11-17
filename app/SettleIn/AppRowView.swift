import SettleInCore
import SwiftUI

/// One catalog app with its state and the buttons that state allows.
struct AppRowView: View {
    let app: CatalogApp
    let state: InstallState
    let onInstall: () -> Void
    let onUninstall: () -> Void
    let onCancel: () -> Void
    let onCopyLog: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.headline)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if case .downloading(let progress) = state {
                    progressView(progress)
                }
                if case .failed(let failure) = state {
                    Text(failure.userMessage)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                buttons
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var buttons: some View {
        if showsInstall {
            Button("Install", action: onInstall).disabled(state.isBusy)
        }
        if showsUninstall {
            Button("Uninstall", action: onUninstall).disabled(state.isBusy)
        }
        if case .downloading = state {
            Button("Cancel", action: onCancel)
        }
        if case .failed = state {
            Button("Copy log", action: onCopyLog)
        }
    }

    private var showsInstall: Bool {
        switch state {
        case .idle, .downloading, .verifying, .installing, .failed: true
        case .installed, .uninstalling: false
        }
    }

    private var showsUninstall: Bool {
        switch state {
        case .installed, .uninstalling, .failed: true
        case .idle, .downloading, .verifying, .installing: false
        }
    }

    @ViewBuilder
    private func progressView(_ progress: Double?) -> some View {
        if let progress {
            ProgressView(value: progress)
                .frame(maxWidth: 240)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)
        }
    }

    private var statusText: String {
        state.statusText(for: app.install)
    }
}
