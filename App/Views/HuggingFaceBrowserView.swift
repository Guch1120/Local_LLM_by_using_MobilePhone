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
                Picker("形式", selection: $ggufOnly) {
                    Text("GGUF").tag(true)
                    Text("すべての形式").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("用途", selection: $use) {
                    ForEach(ModelUse.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(
                    "「画像+テキスト」は画像を入力できるモデルです。画像入力には image projector（mmproj）が必要で、"
                        + "ダウンロードメニューから一緒に入手できます。GGUF モデルは llama.cpp で動きます。"
                        + ".litertlm モデルを探すときは「すべての形式」を選んでください（例: \"litert-community\"）。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            ModelDownloadsSection()
            Section {
                if searching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Hugging Face を検索中です。").font(.footnote)
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
                    Text("モデルが見つかりません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "ダウンロード数の多い順" : "検索結果")
            }
        }
        .navigationTitle("Hugging Face")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "モデルを検索")
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
                    Label("承認が必要", systemImage: "lock")
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
                Label("画像+テキスト", systemImage: "photo").font(.caption).foregroundStyle(.blue)
            case .text?:
                Label("テキスト", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary)
            default:
                Label("非対応: \(pipelineTag)", systemImage: "nosign").font(.caption).foregroundStyle(.orange)
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
                        Text("ファイル一覧を取得中です。").font(.footnote)
                    }
                }
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !loading, loadError == nil, files.isEmpty {
                    Text("このリポジトリには .gguf / .litertlm ファイルがありません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            let models = files.filter { !$0.isProjector && !$0.isDrafter }
            if !models.isEmpty {
                Section {
                    ForEach(models) { file in fileRow(file) }
                } header: {
                    Text("モデルファイル")
                } footer: {
                    Text("量子化の小さいもの（Q4）ほどロードが速く、コンテキストに使えるメモリが増えます。")
                }
            }
            let projectors = files.filter(\.isProjector)
            if !projectors.isEmpty {
                Section {
                    ForEach(projectors) { file in fileRow(file) }
                } header: {
                    Text("画像用プロジェクタ（mmproj）")
                } footer: {
                    Text(
                        "画像入力にはモデル本体とプロジェクタの両方が必要です。モデルのダウンロードメニューから一緒に入手できます。"
                            + "ここで単体でダウンロードしたプロジェクタは、最後にインストールした GGUF モデルに紐付きます。"
                    )
                }
            }
            let drafters = files.filter { $0.isDrafter && !$0.isProjector }
            if !drafters.isEmpty {
                Section {
                    ForEach(drafters) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.fileName).font(.subheadline)
                            Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("単体では使えないファイル")
                } footer: {
                    Text(
                        "MTP ファイルは、本体モデルの生成を速めるための小さな補助モデルです。"
                            + "このアプリでは読み込めないため、ダウンロードの対象外です。"
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
            Label("この iPhone で動作可", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .tight:
            Label("メモリに余裕なし", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .tooLarge:
            Label("大きすぎます", systemImage: "xmark.circle").foregroundStyle(.red)
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
                        Label("画像入力を追加（\(Self.size(projector))）", systemImage: "photo")
                    }
                } label: {
                    Label("インストール済み", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                installedMark
            }
        } else if download?.state == .completed || isInstalled(file) {
            installedMark
        } else if !file.isProjector, file.fileName.lowercased().hasSuffix(".gguf"), let projector = smallestProjector {
            Menu("ダウンロード") {
                Button {
                    appState.startDownload(repository: repository, file: file, projector: projector)
                } label: {
                    Label("画像入力つき（+\(Self.size(projector))）", systemImage: "photo")
                }
                Button {
                    appState.startDownload(repository: repository, file: file)
                } label: {
                    Label("モデルのみ（テキスト）", systemImage: "text.alignleft")
                }
            }
            .buttonStyle(.bordered)
        } else {
            Button("ダウンロード") { appState.startDownload(repository: repository, file: file) }
                .buttonStyle(.bordered)
        }
    }

    private var installedMark: some View {
        Label("インストール済み", systemImage: "checkmark.circle.fill")
            .labelStyle(.iconOnly)
            .foregroundStyle(.green)
            .accessibilityLabel("インストール済み")
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
        case .importing: return "インストール中"
        default: return "待機中"
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
                Text("ダウンロード")
            } footer: {
                Text("ダウンロードはアプリを開いている間だけ進みます。完了するまでアプリを前面に表示しておいてください。")
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
                    Button("再試行") { appState.retryDownload(download.id) }
                        .buttonStyle(.bordered)
                }
                Button { appState.removeDownload(download.id) } label: {
                    Image(systemName: download.isActive ? "xmark.circle" : "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(download.isActive ? "ダウンロードをキャンセル" : "一覧から削除")
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
            return "待機中 · \(total)"
        case .downloading:
            let received = ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file)
            return "\(received) / \(total)"
        case .importing:
            return "検証してインストール中…"
        case .completed:
            return "インストール済み: \(download.modelID ?? download.fileName)"
        case .failed:
            return download.error ?? "ダウンロードに失敗しました。"
        }
    }
}
