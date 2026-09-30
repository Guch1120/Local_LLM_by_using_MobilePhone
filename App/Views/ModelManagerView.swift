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
                // The tab is opened mostly to pick a model to load, so the installed models come first.
                Section {
                    if appState.modelImporting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Documents フォルダからモデルを取り込み中です。")
                                .font(.footnote)
                        }
                    }
                    if appState.modelLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("モデルをロード中です。数分かかることがあります。")
                                .font(.footnote)
                        }
                    }
                    if appState.installedModels.isEmpty {
                        ContentUnavailableView(
                            "モデルがありません",
                            systemImage: "shippingbox",
                            description: Text(
                                "右上の「HFでモデルを探す」からダウンロードするか、"
                                    + ".litertlm / .gguf ファイルを取り込んでください。"
                            )
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(appState.installedModels) { model in
                            modelRow(model)
                        }
                    }
                } header: { Text("インストール済みモデル") }

                ModelDownloadsSection()

                Section {
                    Button { showingImporter = true } label: {
                        Label("モデルファイルを取り込む", systemImage: "square.and.arrow.down")
                    }
                    .disabled(appState.modelLoading)
                    Button { Task { await appState.importModelsFromDocuments() } } label: {
                        Label("Documents フォルダから取り込む", systemImage: "folder")
                    }
                    .disabled(appState.modelLoading || appState.modelImporting)
                    Text("ファイルは Application Support にコピーされ、端末内でハッシュ値を計算します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(
                        "このアプリの Documents フォルダ（「ファイル」アプリまたは USB）に置いた .litertlm / .gguf ファイルは、"
                            + "アプリを開いたときに自動で取り込まれます。名前に mmproj を含む GGUF ファイルは、"
                            + "最後に取り込んだ GGUF モデルに画像入力用として紐付きます。"
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { Text("ローカルストレージから取り込み") }

                // A development aid that is rarely used, so it sits at the bottom.
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("開発用モックバックエンド")
                                .font(.headline)
                            Text("モデルファイルは不要です。API は決まったテスト用の文章を返します。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.metricsSnapshot?.model == "mock-echo" {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                    if appState.metricsSnapshot?.model != "mock-echo" {
                        Button("使用中のモデルをアンロード") { Task { await appState.unloadModel() } }
                            .disabled(appState.modelLoading)
                    }
                } header: { Text("内蔵バックエンド") }

                Section { ErrorBanner().listRowInsets(EdgeInsets()) }
            }
            .navigationTitle("モデル管理")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // A Label is drawn as an icon only in the navigation bar, so the words are spelled out.
                    Button { showingBrowser = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                            Text("HFでモデルを探す")
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Hugging Face でモデルを探す")
                }
            }
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
                Label("テキスト", systemImage: "text.alignleft")
                    .fixedSize()
                if model.modalities.contains("image") {
                    Label("画像", systemImage: "photo")
                        .fixedSize()
                }
                Text(model.backend)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if appState.metricsSnapshot?.model == model.id {
                    Button("アンロード") { Task { await appState.unloadModel() } }
                        .buttonStyle(.bordered)
                        .disabled(appState.modelLoading)
                } else {
                    Button("ロード") { Task { await appState.loadModel(model.id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.modelLoading)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { Task { await appState.removeModel(model.id) } } label: {
                Label("削除", systemImage: "trash")
            }
            .disabled(appState.modelLoading)
        }
    }
}
