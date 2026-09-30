import SwiftUI
import UIKit

/// The request that is running or ran last, as shown on the phone's screen.
/// It holds the prompt, the images and the reply, so it lives in memory only.
struct LiveRequest: Identifiable {
    enum State {
        case generating
        case completed
        /// The output was cut off by the token limit.
        case truncated
        case failed
    }

    let id: String
    let model: String
    /// Text of the last user message.
    let prompt: String
    /// Messages before the last user message (system prompt and earlier turns).
    let earlierMessages: Int
    let images: [UIImage]
    let maxTokens: Int
    let startedAt = Date()
    private(set) var output = ""
    private(set) var state = State.generating
    private(set) var pieces = 0
    private(set) var firstPieceAt: Date?
    private(set) var lastPieceAt: Date?

    init(_ request: InferenceRequest) {
        id = request.id
        model = request.model
        maxTokens = request.maxTokens
        let lastUserIndex = request.messages.lastIndex { $0.role == .user }
        let parts = lastUserIndex.map { request.messages[$0].parts } ?? []
        prompt = parts.compactMap { part -> String? in
            if case let .text(text) = part { return text }
            return nil
        }.joined(separator: "\n")
        earlierMessages = lastUserIndex ?? 0
        // Decode and scale once; the view redraws for every piece of generated text.
        images = parts.compactMap { part -> UIImage? in
            guard case let .image(image) = part, let decoded = UIImage(data: image.data) else { return nil }
            let scale = min(1, 900 / max(decoded.size.width, decoded.size.height, 1))
            let size = CGSize(width: decoded.size.width * scale, height: decoded.size.height * scale)
            return decoded.preparingThumbnail(of: size) ?? decoded
        }
    }

    mutating func append(_ text: String) {
        output += text
        pieces += 1
        firstPieceAt = firstPieceAt ?? Date()
        lastPieceAt = Date()
    }

    mutating func finish(failed: Bool, truncated: Bool) {
        state = failed ? .failed : (truncated ? .truncated : .completed)
    }

    /// Generated pieces per second; a piece is roughly one token.
    var piecesPerSecond: Double? {
        guard pieces > 1, let firstPieceAt, let lastPieceAt, lastPieceAt > firstPieceAt else { return nil }
        return Double(pieces - 1) / lastPieceAt.timeIntervalSince(firstPieceAt)
    }

    var secondsToFirstPiece: Double? { firstPieceAt.map { $0.timeIntervalSince(startedAt) } }
}

/// Prompt, images and streaming reply of one request.
struct LiveRequestView: View {
    let request: LiveRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if request.state == .generating { ProgressView() }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(request.state == .failed || request.state == .truncated ? Color.orange : Color.secondary)
                Spacer()
                Text(request.model)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !request.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(request.images.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 320)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("入力画像")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(request.earlierMessages > 0 ? "入力（これより前に \(request.earlierMessages) 件のメッセージ）" : "入力")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(request.prompt.isEmpty ? "（テキストなし）" : request.prompt)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("出力")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                outputText
            }
        }
        .padding(.vertical, 4)
    }

    private var outputText: some View {
        Text(request.output.isEmpty ? "…" : request.output)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var statusText: String {
        var parts: [String]
        switch request.state {
        case .generating: parts = ["生成中"]
        case .completed: parts = ["完了"]
        case .truncated: parts = ["出力上限（\(request.maxTokens) トークン）で停止"]
        case .failed: parts = ["失敗"]
        }
        if let seconds = request.secondsToFirstPiece {
            parts.append(String(format: "最初のトークンまで %.1f 秒", seconds))
        }
        if let speed = request.piecesPerSecond {
            parts.append(String(format: "%.1f tok/s", speed))
        }
        return parts.joined(separator: " · ")
    }
}

/// The Output tab: the running request, following the reply as it is generated.
struct LiveOutputView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let live = appState.liveRequest {
                            LiveRequestView(request: live)
                        } else {
                            Text("リクエストの実行中、入力テキスト・画像・出力がここに表示されます。")
                                .foregroundStyle(.secondary)
                        }
                        Text("この画面に表示するだけで、入力テキスト・画像・出力は保存もログ記録もしません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .onChange(of: appState.liveRequest?.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .navigationTitle("出力")
        }
    }
}
