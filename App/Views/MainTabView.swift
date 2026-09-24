import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            ServerStatusView()
                .tabItem { Label("Server", systemImage: "dot.radiowaves.left.and.right") }
            ModelManagerView()
                .tabItem { Label("Models", systemImage: "shippingbox") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
            DiagnosticsView()
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            LogsView()
                .tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }
        }
    }
}

struct ErrorBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let message = appState.lastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { appState.clearVisibleError() } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .accessibilityLabel("Dismiss error")
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
