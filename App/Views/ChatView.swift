import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// An image or audio clip attached to a chat message.
struct ChatAttachment: Identifiable {
    enum Kind {
        case image(ImageInput)
        case audio(Data, mimeType: String, duration: TimeInterval)
    }

    let id = UUID()
    let kind: Kind
    let thumbnail: UIImage?

    var part: MessagePart {
        switch kind {
        case let .image(image): return .image(image)
        case let .audio(data, mimeType, _): return .audio(data, mimeType: mimeType)
        }
    }

    var isImage: Bool { if case .image = kind { return true }; return false }
}

struct ChatTurn: Identifiable {
    enum Role { case user, assistant }
    enum State: Equatable {
        case done
        case generating
        /// Cut off by the output token limit.
        case truncated
        case stopped
        case failed(String)
    }

    let id = UUID()
    let role: Role
    var text: String
    var attachments: [ChatAttachment] = []
    var state = State.done
    var usage: TokenUsage?
}

/// A conversation on the phone. Each turn sends the whole conversation again, like an API client
/// does, so it shares the server's limits (context size, thermal pause). Kept in memory only.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var turns: [ChatTurn] = []
    @Published private(set) var isGenerating = false
    private var task: Task<Void, Never>?

    func send(
        text: String,
        attachments: [ChatAttachment],
        model: String,
        maxTokens: Int,
        temperature: Double,
        generate: @escaping (InferenceRequest) async throws -> AsyncThrowingStream<InferenceChunk, Error>
    ) {
        guard !isGenerating else { return }
        turns.append(ChatTurn(role: .user, text: text, attachments: attachments))
        let messages = turns.compactMap { turn -> InferenceMessage? in
            switch (turn.role, turn.state) {
            case (.user, _):
                let parts = (turn.text.isEmpty ? [] : [MessagePart.text(turn.text)]) + turn.attachments.map(\.part)
                return InferenceMessage(role: .user, parts: parts)
            case (.assistant, .failed):
                return nil
            case (.assistant, _):
                return InferenceMessage(role: .assistant, parts: [.text(turn.text)])
            }
        }
        turns.append(ChatTurn(role: .assistant, text: "", state: .generating))
        let request = InferenceRequest(
            id: "chat-\(UUID().uuidString)", model: model, messages: messages,
            maxTokens: maxTokens, temperature: temperature
        )
        isGenerating = true
        task = Task { [weak self] in
            var truncated = false
            var usage: TokenUsage?
            do {
                for try await chunk in try await generate(request) {
                    if !chunk.text.isEmpty { self?.appendToReply(chunk.text) }
                    if chunk.finishReason == "length" { truncated = true }
                    if let chunkUsage = chunk.usage { usage = chunkUsage }
                }
                self?.finishReply(Task.isCancelled ? .stopped : (truncated ? .truncated : .done), usage: usage)
            } catch {
                self?.finishReply(Task.isCancelled ? .stopped : .failed(error.localizedDescription), usage: nil)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    func clear() {
        stop()
        turns.removeAll()
    }

    private func appendToReply(_ text: String) {
        guard let index = turns.indices.last else { return }
        turns[index].text += text
    }

    private func finishReply(_ state: ChatTurn.State, usage: TokenUsage?) {
        if let index = turns.indices.last {
            turns[index].state = state
            turns[index].usage = usage
        }
        isGenerating = false
        task = nil
    }
}

/// The Chat tab: talk to the model on the phone, or watch the requests from the PC.
struct ChatTabView: View {
    enum Pane: String { case chat, api }

    // The `-chatPane api` launch argument opens the PC requests directly.
    @State private var pane = Pane(rawValue: UserDefaults.standard.string(forKey: "chatPane") ?? "") ?? .chat

    var body: some View {
        NavigationStack {
            Group {
                switch pane {
                case .chat: ChatView()
                case .api: LiveOutputView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("表示", selection: $pane) {
                        Text("チャット").tag(Pane.chat)
                        Text("PC からのリクエスト").tag(Pane.api)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }
}

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var session = ChatSession()
    @StateObject private var recorder = AudioRecorder()
    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var showingAudioImporter = false
    @State private var inputError: String?
    @FocusState private var draftFocused: Bool

    private var activeModel: String? {
        guard let snapshot = appState.metricsSnapshot, snapshot.modelLoaded, snapshot.model != "mock-echo" else {
            return nil
        }
        return snapshot.model
    }

    var body: some View {
        VStack(spacing: 0) {
            modelBar
            Divider()
            transcript
            Divider()
            inputBar
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in addImage(image.jpegData(compressionQuality: 0.9)) }
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showingAudioImporter, allowedContentTypes: [.audio]) { result in
            addAudioFile(result)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                addImage(try? await item.loadTransferable(type: Data.self))
                photoItem = nil
            }
        }
        // Drop attachments the newly selected model cannot take.
        .onChange(of: appState.supportsVision) { _, supported in
            if !supported { attachments.removeAll(where: \.isImage) }
        }
        .onChange(of: appState.supportsAudio) { _, supported in
            if !supported { attachments.removeAll { !$0.isImage } }
        }
        .onAppear {
            recorder.onFinish = { data, duration in
                attachments.append(ChatAttachment(kind: .audio(data, mimeType: "audio/wav", duration: duration), thumbnail: nil))
            }
        }
    }

    // MARK: Model

    private var modelBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(appState.installedModels) { model in
                        Button {
                            Task { await appState.loadModel(model.id) }
                        } label: {
                            if model.id == activeModel {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(model.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(activeModel ?? "モデルを選択")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
                .disabled(appState.modelLoading || session.isGenerating || appState.installedModels.isEmpty)
                Spacer()
                Button {
                    session.clear()
                    attachments.removeAll()
                } label: {
                    Label("新しい会話", systemImage: "square.and.pencil")
                }
                .disabled(session.turns.isEmpty)
            }
            HStack(spacing: 10) {
                if appState.modelLoading {
                    ProgressView()
                    Text("モデルをロード中…")
                } else if activeModel == nil {
                    Text(appState.installedModels.isEmpty
                         ? "「モデル」タブでモデルを入手してください。"
                         : "モデルを選ぶと、そのモデルが受け付ける入力が使えるようになります。")
                } else {
                    modality("テキスト", symbol: "text.alignleft", supported: true)
                    modality("画像", symbol: "photo", supported: appState.supportsVision)
                    modality("音声", symbol: "waveform", supported: appState.supportsAudio)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func modality(_ title: String, symbol: String, supported: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: supported ? symbol : "nosign")
            Text(title)
        }
        .foregroundStyle(supported ? Color.accentColor : Color.secondary)
        .opacity(supported ? 1 : 0.5)
        .accessibilityLabel(supported ? "\(title)に対応" : "\(title)には非対応")
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.turns.isEmpty {
                        Text("この iPhone 上のモデルと会話します。入力と出力は端末の外に送られず、保存もされません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(session.turns) { turn in
                        ChatBubble(turn: turn)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.turns.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: session.turns.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let inputError {
                Text(inputError).font(.caption).foregroundStyle(.orange)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                }
            }
            if recorder.isRecording {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    Text(String(format: "録音中 %.1f 秒（最長 %.0f 秒）", recorder.elapsed, AudioRecorder.maximumDuration))
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button("取り消し", role: .destructive) { recorder.cancel() }
                    Button("録音を終了") { recorder.stop() }
                        .buttonStyle(.borderedProminent)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                if appState.supportsVision {
                    Menu {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("写真を選ぶ", systemImage: "photo.on.rectangle")
                        }
                        if CameraPicker.isAvailable {
                            Button { showingCamera = true } label: { Label("写真を撮る", systemImage: "camera") }
                        }
                    } label: {
                        Image(systemName: "photo").font(.title3)
                    }
                    .accessibilityLabel("画像を添付")
                }
                if appState.supportsAudio {
                    Menu {
                        Button { startRecording() } label: { Label("録音する", systemImage: "mic") }
                        Button { showingAudioImporter = true } label: { Label("音声ファイルを選ぶ", systemImage: "folder") }
                    } label: {
                        Image(systemName: "mic").font(.title3)
                    }
                    .disabled(recorder.isRecording)
                    .accessibilityLabel("音声を添付")
                }
                TextField(activeModel == nil ? "モデルを選択してください" : "メッセージ", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($draftFocused)
                if session.isGenerating {
                    Button { session.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("生成を停止")
                } else {
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("送信")
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        activeModel != nil && !appState.modelLoading && !recorder.isRecording
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func send() {
        guard canSend, let model = activeModel else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = attachments
        draft = ""
        attachments = []
        inputError = nil
        draftFocused = false
        session.send(
            text: text, attachments: sent, model: model,
            maxTokens: appState.defaultMaxTokens, temperature: appState.temperature
        ) { request in
            try await appState.generateOnDevice(request)
        }
    }

    private func startRecording() {
        inputError = nil
        Task {
            do {
                try await recorder.start()
            } catch {
                inputError = error.localizedDescription
            }
        }
    }

    private func addImage(_ data: Data?) {
        guard let data else {
            inputError = "画像を読み込めませんでした。"
            return
        }
        do {
            let image = try OpenAIRequestAdapter.normalizeImage(data)
            let thumbnail = UIImage(data: image.data)?.preparingThumbnail(of: CGSize(width: 240, height: 240))
            attachments.append(ChatAttachment(kind: .image(image), thumbnail: thumbnail))
            inputError = nil
        } catch {
            inputError = "画像を読み込めませんでした。"
        }
    }

    private func addAudioFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let clip = try AudioRecorder.wavClip(from: url)
            attachments.append(ChatAttachment(
                kind: .audio(clip.data, mimeType: "audio/wav", duration: clip.duration), thumbnail: nil
            ))
            inputError = nil
        } catch {
            inputError = MediaInputError.unreadableAudio.localizedDescription
        }
    }
}

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AttachmentPreview(attachment: attachment, height: 64)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel("添付を削除")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}

private struct AttachmentPreview: View {
    let attachment: ChatAttachment
    let height: CGFloat

    var body: some View {
        switch attachment.kind {
        case .image:
            if let thumbnail = attachment.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: height, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("添付画像")
            }
        case let .audio(_, _, duration):
            Label(String(format: "音声 %.1f 秒", duration), systemImage: "waveform")
                .font(.caption)
                .padding(.horizontal, 10)
                .frame(height: min(height, 36))
                .background(.thinMaterial, in: Capsule())
        }
    }
}

private struct ChatBubble: View {
    let turn: ChatTurn

    var body: some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 40) }
            VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 6) {
                if !turn.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(turn.attachments) { AttachmentPreview(attachment: $0, height: 96) }
                    }
                }
                if !turn.text.isEmpty || turn.state == .generating {
                    Text(rendered)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(
                            turn.role == .user ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                if let status {
                    Text(status.text)
                        .font(.caption2)
                        .foregroundStyle(status.warning ? Color.orange : Color.secondary)
                }
            }
            if turn.role == .assistant { Spacer(minLength: 40) }
        }
    }

    /// Bold, italics and code in the reply are shown as such; line breaks are kept.
    private var rendered: AttributedString {
        if turn.text.isEmpty { return AttributedString("…") }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: turn.text, options: options)) ?? AttributedString(turn.text)
    }

    private var status: (text: String, warning: Bool)? {
        guard turn.role == .assistant else { return nil }
        let usage = turn.usage.map { "入力 \($0.promptTokens) / 出力 \($0.completionTokens) トークン" }
        switch turn.state {
        case .generating: return ("生成中…", false)
        case .done: return usage.map { (text: $0, warning: false) }
        case .truncated: return ("出力上限で停止" + (usage.map { " · \($0)" } ?? ""), true)
        case .stopped: return ("停止しました", true)
        case let .failed(message): return ("エラー: \(message)", true)
        }
    }
}
