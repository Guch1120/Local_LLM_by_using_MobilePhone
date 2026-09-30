import SwiftUI
import UniformTypeIdentifiers

struct ModelManagerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showingImporter = false
    // `-modelBrowserQuery TEXT` and `-modelBrowserRepository owner/name` launch arguments open
    // the browser directly, so the screens can be checked from a PC without touching the phone.
    @State private var showingBrowser = UserDefaults.standard.string(forKey: "modelBrowserQuery") != nil
        || UserDefaults.standard.string(forKey: "modelBrowserRepository") != nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showingBrowser = true } label: {
                        Label("Browse Hugging Face", systemImage: "magnifyingglass")
                    }
                    Text("Search for GGUF or LiteRT-LM models and download them straight to this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { Text("Get models") }

                ModelDownloadsSection()

                Section {
                    if appState.modelImporting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Importing model files from Documents.")
                                .font(.footnote)
                        }
                    }
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
                        ContentUnavailableView("No imported models", systemImage: "shippingbox", description: Text("Import a compatible .litertlm or .gguf file to register it on this device."))
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
                    Button { Task { await appState.importModelsFromDocuments() } } label: {
                        Label("Import from Documents folder", systemImage: "folder")
                    }
                    .disabled(appState.modelLoading || appState.modelImporting)
                    Text("Files are copied to Application Support and hashed locally.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(
                        ".litertlm and .gguf files placed in this app's Documents folder (Files app or USB) "
                            + "are moved in automatically when the app opens. A GGUF file named mmproj is attached "
                            + "to the most recently imported GGUF model for image input."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section { ErrorBanner().listRowInsets(EdgeInsets()) }
            }
            .navigationTitle("Model manager")
            .navigationDestination(isPresented: $showingBrowser) {
                HuggingFaceBrowserView(
                    initialQuery: UserDefaults.standard.string(forKey: "modelBrowserQuery") ?? "",
                    initialRepository: UserDefaults.standard.string(forKey: "modelBrowserRepository") ?? ""
                )
            }
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
                if model.modalities.contains("image") {
                    Label("Image", systemImage: "photo")
                }
                Text(model.backend)
                    .foregroundStyle(.secondary)
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
