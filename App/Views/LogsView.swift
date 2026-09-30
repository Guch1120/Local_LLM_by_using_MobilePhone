import SwiftUI

struct LogsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                if appState.logEntries.isEmpty {
                    ContentUnavailableView("ログはありません", systemImage: "list.bullet.rectangle", description: Text("サーバーと推論の動作記録がここに表示されます。"))
                } else {
                    ForEach(appState.logEntries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.event.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Text(entry.level.rawValue.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(color(for: entry.level))
                            }
                            Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if let requestID = entry.requestID {
                                Text("リクエスト \(requestID)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            if let details = entry.details {
                                Text(details).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("ログ")
            .refreshable { await appState.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await appState.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("ログを更新")
                }
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        return switch level {
        case .debug: .gray
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
