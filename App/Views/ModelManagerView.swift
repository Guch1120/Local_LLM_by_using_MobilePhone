import SwiftUI
import UniformTypeIdentifiers

struct ModelManagerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if appState.modelLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading model. This can take several minutes.")
                                .font(.footnote)
                        }
                    }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mock development backend")
                                .font(.headline)
                            Text("No model file is required. API responses are deterministic test text.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.metricsSnapshot?.model == "mock-echo" {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    if appState.metricsSnapshot?.model != "mock-echo" {
                        Button("Unload active model") { Task { await appState.unloadModel() } }
                            .disabled(appState.modelLoading)
                    }
                } header: { Text("Built-in backend") }

                Section {
                    if appState.installedModels.isEmpty {
                        ContentUnavailableView("No imported models", systemImage: "shippingbox", description: Text("Import a compatible .litertlm file to register it on this device."))
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(appState.installedModels) { model in
                            modelRow(model)
                        }
                    }
                } header: { Text("Installed models") }

                Section {
                    Button { showingImporter = true } label: {
                        Label("Import model file", systemImage: "square.and.arrow.down")
                    }
                    .disabled(appState.modelLoading)
                    Text("Files are copied to Application Support and hashed locally. Model downloads are not performed by this app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section { ErrorBanner().listRowInsets(EdgeInsets()) }
            }
            .navigationTitle("Model manager")
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: true) { result in
                switch result {
                case let .success(urls): Task { await appState.importModels(from: urls) }
                case let .failure(error): appState.reportError(error.localizedDescription)
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: InstalledModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.name).font(.headline)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(model.id)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("SHA-256  \(model.sha256)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Label("Text", systemImage: "text.alignleft")
                Label("Image", systemImage: "photo")
                Spacer()
                if appState.metricsSnapshot?.model == model.id {
                    Button("Unload") { Task { await appState.unloadModel() } }
                        .buttonStyle(.bordered)
                        .disabled(appState.modelLoading)
                } else {
                    Button("Load") { Task { await appState.loadModel(model.id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.modelLoading)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { Task { await appState.removeModel(model.id) } } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(appState.modelLoading)
        }
    }
}
