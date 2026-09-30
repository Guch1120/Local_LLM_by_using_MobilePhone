import SwiftUI

struct MainTabView: View {
    // The `-initialTab models` launch argument opens a tab directly (see scripts/iphone/launch.sh).
    @State private var selection = UserDefaults.standard.string(forKey: "initialTab") ?? "server"

    var body: some View {
        TabView(selection: $selection) {
            ServerStatusView()
                .tabItem { Label("サーバー", systemImage: "dot.radiowaves.left.and.right") }
                .tag("server")
            ModelManagerView()
                .tabItem { Label("モデル", systemImage: "shippingbox") }
                .tag("models")
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag("settings")
            DiagnosticsView()
                .tabItem { Label("診断", systemImage: "waveform.path.ecg") }
                .tag("diagnostics")
            LogsView()
                .tabItem { Label("ログ", systemImage: "list.bullet.rectangle") }
                .tag("logs")
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
                .accessibilityLabel("エラーを閉じる")
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
