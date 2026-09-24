import Foundation
import LiteRTLM

actor LiteRTGemmaBackend: InferenceBackend {
    nonisolated let identifier = "litert-lm"

    private var engine: Engine?
    private var loadedModel: String?
    private var modelLoadMilliseconds: Double?
    private var selectedBackend = "gpu"
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
        ExperimentalFlags.enableSpeculativeDecoding = configuration.multiTokenPredictionEnabled
        var effectiveMTP = configuration.multiTokenPredictionEnabled
        do {
            let gpuConfig = try EngineConfig(
                modelPath: configuration.fileURL.path,
                backend: .gpu,
                visionBackend: .cpu(),
                maxNumTokens: configuration.contextTokens,
                cacheDir: cacheURL.path
            )
            let gpuEngine = Engine(engineConfig: gpuConfig)
            try await gpuEngine.initialize()
            engine = gpuEngine
            selectedBackend = "gpu"
        } catch {
            // A GPU initialization failure should not prevent the text API from being used.
            // iOS third-party Metal availability varies by LiteRT-LM build and device.
            if effectiveMTP {
                ExperimentalFlags.enableSpeculativeDecoding = false
                effectiveMTP = false
            }
            let cpuConfig = try EngineConfig(
                modelPath: configuration.fileURL.path,
                backend: .cpu(),
                visionBackend: .cpu(),
                maxNumTokens: configuration.contextTokens,
                cacheDir: cacheURL.path
            )
            let cpuEngine = Engine(engineConfig: cpuConfig)
            do {
                try await cpuEngine.initialize()
                engine = cpuEngine
                selectedBackend = "cpu"
            } catch {
                throw InferenceError.backendUnavailable("LiteRT-LM could not initialize this model on GPU or CPU: \(error.localizedDescription)")
            }
        }
        loadedModel = configuration.id
        multiTokenPredictionEnabled = effectiveMTP
        modelLoadMilliseconds = Date().timeIntervalSince(start) * 1000
    }

    func unloadModel() async {
        engine = nil
        loadedModel = nil
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
        BackendCapabilities(text: true, image: true, audio: false, streaming: true)
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
