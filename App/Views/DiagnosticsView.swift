import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("App build") {
                    metric("Version / build", value: appBuildText, symbol: "number.square")
                    metric("Git revision", value: gitRevision, symbol: "chevron.left.forwardslash.chevron.right")
                    metric("Saved log entries", value: "\(appState.logPersistenceStatus?.entryCount ?? appState.logEntries.count)", symbol: "externaldrive")
                    metric("Log storage", value: logStorageText, symbol: "checkmark.icloud")
                    if let error = appState.logPersistenceStatus?.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Section("Device") {
                    metric("Thermal state", value: appState.metricsSnapshot?.thermalState.capitalized ?? "—", symbol: "thermometer.medium")
                    metric("Physical footprint", value: memoryText, symbol: "memorychip")
                    metric("Uptime", value: uptimeText, symbol: "clock")
                }
                Section("Last inference") {
                    if let last = appState.metricsSnapshot?.lastInference {
                        metric("Prompt tokens (estimated)", value: "\(last.promptTokens)", symbol: "text.alignleft")
                        metric("Generated tokens (estimated)", value: "\(last.generatedTokens)", symbol: "text.alignleft")
                        metric("Time to first token", value: milliseconds(last.ttftMilliseconds), symbol: "bolt")
                        metric("Decode speed", value: String(format: "%.2f tok/s", last.decodeTokensPerSecond), symbol: "speedometer")
                        metric("Total latency", value: milliseconds(last.totalLatencyMilliseconds), symbol: "timer")
                    } else {
                        Text("No inference requests yet.").foregroundStyle(.secondary)
                    }
                    if let load = appState.metricsSnapshot?.modelLoadMilliseconds {
                        metric("Model load time", value: milliseconds(load), symbol: "shippingbox")
                    }
                }
                Section("Benchmarks") {
                    Button {
                        Task { await appState.runTextBenchmark() }
                    } label: {
                        Label("Run text benchmark", systemImage: "text.alignleft")
                    }
                    .disabled(appState.benchmarkRunning || appState.modelLoading)
                    Button {
                        Task { await appState.runVisionBenchmark() }
                    } label: {
                        Label("Run vision benchmark", systemImage: "viewfinder")
                    }
                    .disabled(!appState.supportsVision || appState.benchmarkRunning || appState.modelLoading)
                    if appState.benchmarkRunning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Benchmark running…")
                        }
                    }
                    Text("Results appear in Last inference and GET /metrics. Vision uses a fixed image with a blue square and a red circle.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Latest error") {
                    Text(appState.lastError ?? "No recent error.")
                        .foregroundStyle(appState.lastError == nil ? Color.gray : Color.red)
                }
                Section("Server") {
                    metric("Requests", value: "\(appState.metricsSnapshot?.requestsTotal ?? 0)", symbol: "arrow.left.arrow.right")
                    metric("Failed requests", value: "\(appState.metricsSnapshot?.requestsFailed ?? 0)", symbol: "exclamationmark.triangle")
                    metric("Active requests", value: "\(appState.metricsSnapshot?.activeRequests ?? 0)", symbol: "ellipsis")
                }
                Section { ErrorBanner().listRowInsets(EdgeInsets()) }
            }
            .navigationTitle("Diagnostics")
            .refreshable { await appState.refresh() }
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        LabeledContent {
            Text(value).monospacedDigit()
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var memoryText: String {
        guard let megabytes = appState.metricsSnapshot?.physicalFootprintMB else { return "—" }
        return String(format: "%.1f MB", megabytes)
    }

    private var appBuildText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    private var gitRevision: String {
        let revision = Bundle.main.infoDictionary?["GitCommitSHA"] as? String ?? "unknown"
        return revision.count > 12 ? String(revision.prefix(12)) : revision
    }

    private var logStorageText: String {
        guard let status = appState.logPersistenceStatus else { return "Checking…" }
        if !status.enabled { return "In memory only" }
        return status.healthy ? "Saved on iPhone" : "Save error"
    }

    private var uptimeText: String {
        guard let seconds = appState.metricsSnapshot?.uptimeSeconds else { return "—" }
        return Duration.seconds(Int64(seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    private func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
}
