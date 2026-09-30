import SwiftUI

/// Searches Hugging Face for model repositories, like the discover screen of a desktop model manager.
struct HuggingFaceBrowserView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query: String
    @State private var ggufOnly = true
    @State private var use = ModelUse.any
    @State private var results: [HuggingFaceModelSummary] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var showingInitialRepository: Bool
    private let initialRepository: String

    /// - Parameter initialRepository: Opens that repository right away (used by launch arguments).
    init(initialQuery: String = "", initialRepository: String = "") {
        _query = State(initialValue: initialQuery)
        _showingInitialRepository = State(initialValue: !initialRepository.isEmpty)
        self.initialRepository = initialRepository
    }

    var body: some View {
        List {
            Section {
                Picker("Format", selection: $ggufOnly) {
                    Text("GGUF").tag(true)
                    Text("All formats").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("Use", selection: $use) {
                    ForEach(ModelUse.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(
                    "Image + text lists models that take pictures; they need an image projector (mmproj), "
                        + "which the download menu adds. GGUF models run on llama.cpp. "
                        + "Choose All formats to find .litertlm models (for example \"litert-community\")."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            ModelDownloadsSection()
            Section {
                if searching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching Hugging Face.").font(.footnote)
                    }
                }
                if let searchError {
                    Label(searchError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ForEach(results) { model in
                    NavigationLink {
                        HuggingFaceRepositoryView(repository: model.id)
                    } label: {
                        resultRow(model)
                    }
                }
                if !searching, searchError == nil, results.isEmpty {
                    Text("No models found.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Most downloaded" : "Results")
            }
        }
        .navigationTitle("Hugging Face")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: ggufOnly) { _, _ in Task { await search() } }
        .onChange(of: use) { _, _ in Task { await search() } }
        .task { if results.isEmpty { await search() } }
        .navigationDestination(isPresented: $showingInitialRepository) {
            HuggingFaceRepositoryView(repository: initialRepository)
        }
    }

    private func resultRow(_ model: HuggingFaceModelSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.id)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 12) {
                Label(Self.compact(model.downloads), systemImage: "arrow.down.circle")
                Label(Self.compact(model.likes), systemImage: "heart")
                if model.gated {
                    Label("Gated", systemImage: "lock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            useLabel(model.pipelineTag)
        }
        .padding(.vertical, 2)
    }

    /// What the model is for. Kinds this app cannot run (speech, image generation, ...) are marked.
    @ViewBuilder
    private func useLabel(_ pipelineTag: String?) -> some View {
        if let pipelineTag {
            switch ModelUse.supported(pipelineTag: pipelineTag) {
            case .vision?:
                Label("Image + text", systemImage: "photo").font(.caption).foregroundStyle(.blue)
            case .text?:
                Label("Text", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary)
            default:
                Label("Not supported: \(pipelineTag)", systemImage: "nosign").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func search() async {
        searching = true
        defer { searching = false }
        do {
            results = try await appState.huggingFaceClient.search(query: query, ggufOnly: ggufOnly, use: use)
            searchError = nil
        } catch is CancellationError {
            return
        } catch {
            results = []
            searchError = error.localizedDescription
        }
    }

    private static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

/// Lists the model files of one repository and starts downloads.
struct HuggingFaceRepositoryView: View {
    @EnvironmentObject private var appState: AppState
    let repository: String
    @State private var files: [HuggingFaceFile] = []
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        List {
            Section {
                Text(repository)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the file list.").font(.footnote)
                    }
                }
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !loading, loadError == nil, files.isEmpty {
                    Text("This repository has no .gguf or .litertlm files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            let models = files.filter { !$0.isProjector }
            if !models.isEmpty {
                Section {
                    ForEach(models) { file in fileRow(file) }
                } header: {
                    Text("Model files")
                } footer: {
                    Text("Smaller quantizations (Q4) load faster and leave more memory for the context.")
                }
            }
            let projectors = files.filter(\.isProjector)
            if !projectors.isEmpty {
                Section {
                    ForEach(projectors) { file in fileRow(file) }
                } header: {
                    Text("Image projectors")
                } footer: {
                    Text(
                        "Image input needs the model and a projector. The model's download menu adds one; "
                            + "a projector downloaded here attaches to the most recently installed GGUF model."
                    )
                }
            }
            ModelDownloadsSection()
            Section { ErrorBanner().listRowInsets(EdgeInsets()) }
        }
        .navigationTitle(repository.split(separator: "/").last.map { String($0) } ?? repository)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func fileRow(_ file: HuggingFaceFile) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(file.fileName)
                    .font(.subheadline)
                    .lineLimit(3)
                HStack(spacing: 10) {
                    Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                    if !file.isProjector { fitLabel(ModelFit.estimate(sizeBytes: file.sizeBytes)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            fileAction(file)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func fitLabel(_ fit: ModelFit) -> some View {
        switch fit {
        case .comfortable:
            Label("Fits this iPhone", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .tight:
            Label("Tight on memory", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .tooLarge:
            Label("Too large", systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func fileAction(_ file: HuggingFaceFile) -> some View {
        let download = appState.downloads.first { $0.repository == repository && $0.path == file.path }
        if let download, download.isActive {
            Text(progressText(download))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if let installed = installedModel(file), let projector = smallestProjector {
            if installed.projectorPath == nil {
                Menu {
                    Button {
                        appState.startProjectorDownload(repository: repository, projector: projector, modelID: installed.id)
                    } label: {
                        Label("Add image input (\(Self.size(projector)))", systemImage: "photo")
                    }
                } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                installedMark
            }
        } else if download?.state == .completed || isInstalled(file) {
            installedMark
        } else if !file.isProjector, file.fileName.lowercased().hasSuffix(".gguf"), let projector = smallestProjector {
            Menu("Download") {
                Button {
                    appState.startDownload(repository: repository, file: file, projector: projector)
                } label: {
                    Label("With image input (+\(Self.size(projector)))", systemImage: "photo")
                }
                Button {
                    appState.startDownload(repository: repository, file: file)
                } label: {
                    Label("Model only (text)", systemImage: "text.alignleft")
                }
            }
            .buttonStyle(.bordered)
        } else {
            Button("Download") { appState.startDownload(repository: repository, file: file) }
                .buttonStyle(.bordered)
        }
    }

    private var installedMark: some View {
        Label("Installed", systemImage: "checkmark.circle.fill")
            .labelStyle(.iconOnly)
            .foregroundStyle(.green)
            .accessibilityLabel("Installed")
    }

    /// The projector offered with a model: the smallest one keeps memory free for the model.
    private var smallestProjector: HuggingFaceFile? {
        files.filter(\.isProjector).min { $0.sizeBytes < $1.sizeBytes }
    }

    private func installedModel(_ file: HuggingFaceFile) -> InstalledModel? {
        guard !file.isProjector, file.fileName.lowercased().hasSuffix(".gguf") else { return nil }
        return appState.installedModels.first { $0.name == file.baseName }
    }

    private static func size(_ file: HuggingFaceFile) -> String {
        ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)
    }

    private func progressText(_ download: ModelDownload) -> String {
        switch download.state {
        case .downloading: return download.fraction.formatted(.percent.precision(.fractionLength(0)))
        case .importing: return "Installing"
        default: return "Queued"
        }
    }

    private func isInstalled(_ file: HuggingFaceFile) -> Bool {
        !file.isProjector && appState.installedModels.contains { $0.name == file.baseName }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            files = try await appState.huggingFaceClient.modelFiles(repository: repository)
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// Progress of the Hugging Face downloads; hidden while there are none.
struct ModelDownloadsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if !appState.downloads.isEmpty {
            Section {
                ForEach(appState.downloads) { download in row(download) }
            } header: {
                Text("Downloads")
            } footer: {
                Text("Downloads run while the app is open. Keep the app in the foreground until they finish.")
            }
        }
    }

    private func row(_ download: ModelDownload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(download.fileName)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer()
                if download.state == .failed {
                    Button("Retry") { appState.retryDownload(download.id) }
                        .buttonStyle(.bordered)
                }
                Button { appState.removeDownload(download.id) } label: {
                    Image(systemName: download.isActive ? "xmark.circle" : "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(download.isActive ? "Cancel download" : "Remove from list")
            }
            if download.state == .downloading {
                ProgressView(value: download.fraction)
            }
            Text(status(download))
                .font(.caption)
                .foregroundStyle(download.state == .failed ? Color.orange : Color.secondary)
        }
        .padding(.vertical, 2)
    }

    private func status(_ download: ModelDownload) -> String {
        let total = ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file)
        switch download.state {
        case .queued:
            return "Waiting · \(total)"
        case .downloading:
            let received = ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file)
            return "\(received) of \(total)"
        case .importing:
            return "Verifying and installing…"
        case .completed:
            return "Installed as \(download.modelID ?? download.fileName)"
        case .failed:
            return download.error ?? "The download failed."
        }
    }
}
