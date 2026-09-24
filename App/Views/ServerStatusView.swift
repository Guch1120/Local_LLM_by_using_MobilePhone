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
                            Text(appState.serverRunning ? "Server running" : (appState.serverStarting ? "Starting server…" : "Server stopped"))
                                .font(.headline)
                            Text("Foreground service · port \(appState.port)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.serverStarting { ProgressView() }
                    }
                    .padding(.vertical, 6)
                    LabeledContent("Model", value: appState.metricsSnapshot?.model ?? "None")
                    LabeledContent("Model loaded", value: appState.metricsSnapshot?.modelLoaded == true ? "Yes" : "No")
                    LabeledContent("Backend", value: appState.metricsSnapshot?.backend ?? "—")
                    LabeledContent("Thermal state", value: appState.metricsSnapshot?.thermalState.capitalized ?? "—")
                    LabeledContent("Memory", value: memoryText)
                    LabeledContent("Last decode speed", value: speedText)
                    Button {
                        Task {
                            if appState.serverRunning { await appState.stopServer() }
                            else { await appState.startServer() }
                        }
                    } label: {
                        Label(appState.serverRunning ? "Stop server" : "Start server", systemImage: appState.serverRunning ? "stop.fill" : "play.fill")
                    }
                    .disabled(appState.serverStarting)
                    if appState.serverRunning {
                        Text("The screen stays awake while the server is running.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Server status")
                }

                Section("PC connection") {
                    LabeledContent("USB endpoint", value: "127.0.0.1:\(appState.port)")
                    Text("On Ubuntu, forward the device port with `iproxy \(appState.port):\(appState.port)`, then connect to this address.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("API key authentication is enabled. The LAN listener is \(appState.allowLAN ? "enabled" : "disabled").")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("OpenAI-compatible API") {
                    Text("GET  /v1/models")
                    Text("POST /v1/chat/completions")
                    Text("SSE streaming · JPEG/PNG data URLs")
                        .foregroundStyle(.secondary)
                }
                if !appState.serverRunning, let error = appState.lastError {
                    Section("Startup error") { Text(error).foregroundStyle(.red) }
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
