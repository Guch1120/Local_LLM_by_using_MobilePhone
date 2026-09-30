import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        LogsView()
                    } label: {
                        Label("ログ", systemImage: "list.bullet.rectangle")
                    }
                }
                Section("アプリのビルド") {
                    metric("バージョン / ビルド", value: appBuildText, symbol: "number.square")
                    metric("Git リビジョン", value: gitRevision, symbol: "chevron.left.forwardslash.chevron.right")
                    metric("保存済みログ件数", value: "\(appState.logPersistenceStatus?.entryCount ?? appState.logEntries.count)", symbol: "externaldrive")
                    metric("ログの保存先", value: logStorageText, symbol: "checkmark.icloud")
                    if let error = appState.logPersistenceStatus?.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Section("デバイス") {
                    metric("発熱状態", value: appState.metricsSnapshot?.thermalState.capitalized ?? "—", symbol: "thermometer.medium")
                    metric("メモリ使用量", value: memoryText, symbol: "memorychip")
                    metric("稼働時間", value: uptimeText, symbol: "clock")
                }
                Section("直前の推論") {
                    if let last = appState.metricsSnapshot?.lastInference {
                        metric("入力トークン数（推定）", value: "\(last.promptTokens)", symbol: "text.alignleft")
                        metric("生成トークン数（推定）", value: "\(last.generatedTokens)", symbol: "text.alignleft")
                        metric("最初のトークンまでの時間", value: milliseconds(last.ttftMilliseconds), symbol: "bolt")
                        metric("生成速度", value: String(format: "%.2f tok/s", last.decodeTokensPerSecond), symbol: "speedometer")
                        metric("合計時間", value: milliseconds(last.totalLatencyMilliseconds), symbol: "timer")
                    } else {
                        Text("まだ推論リクエストはありません。").foregroundStyle(.secondary)
                    }
                    if let load = appState.metricsSnapshot?.modelLoadMilliseconds {
                        metric("モデルのロード時間", value: milliseconds(load), symbol: "shippingbox")
                    }
                }
                Section("ベンチマーク") {
                    Button {
                        Task { await appState.runTextBenchmark() }
                    } label: {
                        Label("テキストのベンチマークを実行", systemImage: "text.alignleft")
                    }
                    .disabled(appState.benchmarkRunning || appState.modelLoading)
                    Button {
                        Task { await appState.runVisionBenchmark() }
                    } label: {
                        Label("画像のベンチマークを実行", systemImage: "viewfinder")
                    }
                    .disabled(!appState.supportsVision || appState.benchmarkRunning || appState.modelLoading)
                    if appState.benchmarkRunning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("ベンチマーク実行中…")
                        }
                    }
                    Text("結果は「直前の推論」と GET /metrics に表示されます。画像のベンチマークは、青い四角と赤い円を描いた固定の画像を使います。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("直近のエラー") {
                    Text(appState.lastError ?? "最近のエラーはありません。")
                        .foregroundStyle(appState.lastError == nil ? Color.gray : Color.red)
                }
                Section("サーバー") {
                    metric("リクエスト数", value: "\(appState.metricsSnapshot?.requestsTotal ?? 0)", symbol: "arrow.left.arrow.right")
                    metric("失敗したリクエスト", value: "\(appState.metricsSnapshot?.requestsFailed ?? 0)", symbol: "exclamationmark.triangle")
                    metric("実行中のリクエスト", value: "\(appState.metricsSnapshot?.activeRequests ?? 0)", symbol: "ellipsis")
                }
                Section { ErrorBanner().listRowInsets(EdgeInsets()) }
            }
            .navigationTitle("診断")
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
        guard let status = appState.logPersistenceStatus else { return "確認中…" }
        if !status.enabled { return "メモリ上のみ" }
        return status.healthy ? "iPhone に保存" : "保存エラー"
    }

    private var uptimeText: String {
        guard let seconds = appState.metricsSnapshot?.uptimeSeconds else { return "—" }
        return Duration.seconds(Int64(seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
    }

    private func milliseconds(_ value: Double) -> String { String(format: "%.0f ms", value) }
}
