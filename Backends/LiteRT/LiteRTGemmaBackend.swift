import Foundation
import LiteRTLM

actor LiteRTGemmaBackend: InferenceBackend {
    nonisolated let identifier = "litert-lm"

    private var engine: Engine?
    private var loadedModel: String?
    private var modelLoadMilliseconds: Double?
    private var selectedBackend = "gpu"
    private var visionBackend: String?
    private var multiTokenPredictionEnabled = false

    func loadModel(configuration: ModelConfiguration) async throws {
        guard configuration.fileURL.pathExtension.lowercased() == "litertlm" else {
            throw InferenceError.backendUnavailable("LiteRT-LM imports require a .litertlm model file.")
        }
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteRT-LM", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

        let start = Date()
        ExperimentalFlags.optIntoExperimentalAPIs()
        var lastError: Error?
        for attempt in Self.attempts() {
            // MTP is only kept on the GPU path; CPU fallbacks run without it.
            let mtp = configuration.multiTokenPredictionEnabled && attempt.backend == .gpu
            ExperimentalFlags.enableSpeculativeDecoding = mtp
            do {
                let config = try EngineConfig(
                    modelPath: configuration.fileURL.path,
                    backend: attempt.backend,
                    visionBackend: attempt.vision,
                    maxNumTokens: configuration.contextTokens,
                    cacheDir: cacheURL.path
                )
                let candidate = Engine(engineConfig: config)
                try await candidate.initialize()
                // Some executors only fail when a conversation is created (for example the
                // GPU vision encoder on iOS: STABLEHLO_COMPOSITE is missing), so probe one.
                _ = try await candidate.createConversation()
                engine = candidate
                selectedBackend = attempt.backend.rawValue
                visionBackend = attempt.vision?.rawValue
                multiTokenPredictionEnabled = mtp
                loadedModel = configuration.id
                modelLoadMilliseconds = Date().timeIntervalSince(start) * 1000
                return
            } catch {
                lastError = error
            }
        }
        ExperimentalFlags.enableSpeculativeDecoding = false
        let reason = lastError?.localizedDescription ?? "no configuration was attempted"
        throw InferenceError.backendUnavailable("LiteRT-LM could not initialize this model: \(reason)")
    }

    /// Engine configurations tried in order until one initializes and can open a conversation.
    ///
    /// Image input is off by default: with LiteRT-LM 0.17.1 the GPU vision encoder always fails
    /// on iOS (STABLEHLO_COMPOSITE), and every failed attempt leaves address space behind that a
    /// later model load needs. The CPU (XNNPACK) vision encoder can hang forever (LiteRT-LM
    /// issues #2979 and #2370), which wedges the whole server. Both stay available for
    /// experiments through `LITERT_VISION_BACKEND=gpu` or `cpu`. Use a GGUF model for images.
    private static func attempts() -> [(backend: Backend, vision: Backend?)] {
        switch ProcessInfo.processInfo.environment["LITERT_VISION_BACKEND"] {
        case "gpu":
            return [(.gpu, .gpu), (.gpu, nil), (.cpu(), nil)]
        case "cpu":
            return [(.gpu, .cpu()), (.cpu(), .cpu())]
        default:
            return [(.gpu, nil), (.cpu(), nil)]
        }
    }

    func unloadModel() async {
        engine = nil
        loadedModel = nil
        visionBackend = nil
        modelLoadMilliseconds = nil
        multiTokenPredictionEnabled = false
    }

    func generate(request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceChunk, Error> {
        guard let engine, loadedModel == request.model else { throw InferenceError.modelNotLoaded }
        let systemText = request.messages
            .filter { $0.role == .system }
            .flatMap(\.parts)
            .compactMap { part -> String? in if case let .text(text) = part { return text }; return nil }
            .joined(separator: "\n")
        let conversationMessages = request.messages
            .filter { $0.role != .system }
            .map(Self.convertMessage)
        guard let finalMessage = conversationMessages.last else {
            throw RequestValidationError.invalid("At least one message is required.")
        }
        let samplerConfig = try SamplerConfig(topK: 40, topP: 0.95, temperature: Float(request.temperature))
        let conversationConfig = ConversationConfig(
            systemMessage: systemText.isEmpty ? nil : Message(systemText, role: .system),
            initialMessages: Array(conversationMessages.dropLast()),
            samplerConfig: samplerConfig
        )
        let conversation = try await engine.createConversation(with: conversationConfig)
        let maxTokens = request.maxTokens

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await response in conversation.sendMessageStream(finalMessage, maxOutputTokens: maxTokens) {
                        let text = response.toString
                        if !text.isEmpty { continuation.yield(InferenceChunk(text: text)) }
                    }
                    continuation.yield(InferenceChunk(text: "", finishReason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                try? conversation.cancel()
            }
        }
    }

    func capabilities() async -> BackendCapabilities {
        BackendCapabilities(text: true, image: visionBackend != nil, audio: false, streaming: true)
    }

    func metrics() async -> BackendMetrics {
        BackendMetrics(loadedModel: loadedModel, modelLoadMilliseconds: modelLoadMilliseconds, computeBackend: selectedBackend, multiTokenPredictionEnabled: multiTokenPredictionEnabled)
    }

    private static func convertMessage(_ message: InferenceMessage) -> Message {
        var contents: [Content] = []
        for part in message.parts {
            switch part {
            case let .text(text):
                contents.append(.text(text))
            case let .image(image):
                contents.append(.imageData(image.data))
            case .audio:
                contents.append(.text("[Audio input was omitted by this API adapter.]"))
            case let .tool(call):
                contents.append(.text("[Tool \(call.name): \(call.argumentsJSON)]"))
            }
        }
        if contents.isEmpty { contents.append(.text("")) }
        let role: Role
        switch message.role {
        case .system: role = .system
        case .user: role = .user
        case .assistant: role = .model
        case .tool: role = .tool
        }
        return Message(contents: contents, role: role)
    }
}
