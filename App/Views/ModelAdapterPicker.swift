import SwiftUI

/// Chooses which LoRA adapter a llama.cpp model applies, and removes adapters.
/// Shown under a model in the model tab once an adapter file has been imported for it.
struct ModelAdapterPicker: View {
    @EnvironmentObject private var appState: AppState
    let model: InstalledModel

    var body: some View {
        if let adapters = model.adapters, !adapters.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("アダプタ", selection: selection) {
                        Text("なし").tag(String?.none)
                        ForEach(adapters) { adapter in
                            Text("\(adapter.name)（\(size(of: adapter))）").tag(String?.some(adapter.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(appState.modelLoading)
                    Spacer()
                    removeMenu(adapters)
                }
                Text("選んだアダプタは、モデルをロードするときに適用されます。切り替えると、ロード済みのモデルは読み込み直されます。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.activeAdapterID },
            set: { id in Task { await appState.selectAdapter(modelID: model.id, adapterID: id) } }
        )
    }

    private func removeMenu(_ adapters: [ModelAdapter]) -> some View {
        Menu {
            ForEach(adapters) { adapter in
                Button(role: .destructive) {
                    Task { await appState.removeAdapter(modelID: model.id, adapterID: adapter.id) }
                } label: {
                    Text("\(adapter.name) を削除")
                }
            }
        } label: {
            Label("アダプタを削除", systemImage: "trash")
                .font(.caption)
        }
        .disabled(appState.modelLoading)
    }

    private func size(of adapter: ModelAdapter) -> String {
        ByteCountFormatter.string(fromByteCount: adapter.sizeBytes, countStyle: .file)
    }
}
