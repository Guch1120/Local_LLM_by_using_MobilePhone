import SwiftUI

struct ServerStatusView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: appState.serverRunning ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(appState.serverRunning ? Color.green : Color.gray)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appState.serverRunning ? "サーバー稼働中" : (appState.serverStarting ? "サーバーを起動中…" : "サーバー停止中"))
                                .font(.headline)
                            Text("フォアグラウンドで動作 · ポート \(String(appState.port))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.serverStarting { ProgressView() }
                    }
                    .padding(.vertical, 6)
                    LabeledContent("モデル", value: appState.metricsSnapshot?.model ?? "なし")
                    LabeledContent("ロード状態", value: appState.metricsSnapshot?.modelLoaded == true ? "ロード済み" : "未ロード")
                    LabeledContent("バックエンド", value: appState.metricsSnapshot?.backend ?? "—")
                    LabeledContent("発熱状態", value: appState.metricsSnapshot?.thermalState.capitalized ?? "—")
                    LabeledContent("メモリ", value: memoryText)
                    LabeledContent("直前の生成速度", value: speedText)
                    Button {
                        Task {
                            if appState.serverRunning { await appState.stopServer() }
                            else { await appState.startServer() }
                        }
                    } label: {
                        Label(appState.serverRunning ? "サーバーを停止" : "サーバーを起動", systemImage: appState.serverRunning ? "stop.fill" : "play.fill")
                    }
                    .disabled(appState.serverStarting)
                    if appState.serverRunning {
                        Text("サーバーの稼働中は画面が消灯しません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("サーバーの状態")
                }

                Section("PC との接続") {
                    LabeledContent("USB 接続先", value: "127.0.0.1:\(appState.port)")
                    Text("Ubuntu 側で `iproxy \(String(appState.port)):\(String(appState.port))` などでポートを転送し、このアドレスに接続します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("API キーによる認証が有効です。LAN からの接続は\(appState.allowLAN ? "有効" : "無効")です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("OpenAI 互換 API") {
                    Text("GET  /v1/models")
                    Text("POST /v1/chat/completions")
                    Text("SSE ストリーミング · JPEG/PNG の data URL")
                        .foregroundStyle(.secondary)
                }
                if !appState.serverRunning, let error = appState.lastError {
                    Section("起動エラー") { Text(error).foregroundStyle(.red) }
                }
                Section { ErrorBanner().listRowInsets(EdgeInsets()) }
            }
            .navigationTitle("iPhone Local AI")
            .refreshable { await appState.refresh() }
        }
    }

    private var memoryText: String {
        guard let megabytes = appState.metricsSnapshot?.physicalFootprintMB else { return "—" }
        return String(format: "%.0f MB", megabytes)
    }

    private var speedText: String {
        guard let speed = appState.metricsSnapshot?.lastInference?.decodeTokensPerSecond else { return "—" }
        return String(format: "%.2f tok/s", speed)
    }
}
