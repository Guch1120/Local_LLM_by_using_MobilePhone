import SwiftUI
import UIKit

struct MainTabView: View {
    // The `-initialTab models` launch argument opens a tab directly (see scripts/iphone/launch.sh).
    // A tab bar holds five tabs, so the logs are opened from the Diagnostics tab.
    @State private var selection = UserDefaults.standard.string(forKey: "initialTab") ?? "server"

    var body: some View {
        TabView(selection: $selection) {
            ServerStatusView()
                .tabItem { Label("サーバー", systemImage: "dot.radiowaves.left.and.right") }
                .tag("server")
            LiveOutputView()
                .tabItem { Label("出力", systemImage: "text.bubble") }
                .tag("output")
            ModelManagerView()
                .tabItem { Label("モデル", systemImage: "shippingbox") }
                .tag("models")
            SettingsView()
                .tabItem { Label("設定", systemImage: "gearshape") }
                .tag("settings")
            DiagnosticsView()
                .tabItem { Label("診断", systemImage: "waveform.path.ecg") }
                .tag("diagnostics")
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

extension View {
    /// Lets the keyboard be closed on screens with text input. iOS has no hide-keyboard key:
    /// the 完了 button above the keyboard works for every field (the number pad has no return
    /// key), and dragging the list down dismisses it too.
    func keyboardDismissible() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                        )
                    }
                }
            }
    }
}
