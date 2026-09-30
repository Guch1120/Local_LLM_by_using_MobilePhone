import Foundation
import llama

/// llama.cpp backend for GGUF models, with image input through libmtmd when a
/// multimodal projector (mmproj) is installed next to the model.
///
/// LiteRT-LM 0.17.1 cannot run the Gemma 4 vision encoder on iOS, so this backend
/// provides image understanding on the Metal GPU.
actor LlamaCppBackend: InferenceBackend {
    nonisolated let identifier = "llama.cpp"

    private var runtime: LlamaRuntime?
    private var loadedModel: String?
    private var modelLoadMilliseconds: Double?

    func loadModel(configuration: ModelConfiguration) async throws {
        guard configuration.fileURL.pathExtension.lowercased() == "gguf" else {
            throw InferenceError.backendUnavailable("llama.cpp requires a .gguf model file.")
        }
        await unloadModel()
        let start = Date()
        let config = configuration
        // Loading maps several gigabytes and compiles Metal kernels; keep it off the actor.
        runtime = try await Task.detached(priority: .userInitiated) {
            try LlamaRuntime(
                modelPath: config.fileURL.path,
                projectorPath: config.projectorURL?.path,
                contextTokens: config.contextTokens
            )
        }.value
        loadedModel = configuration.id
        modelLoadMilliseconds = Date().timeIntervalSince(start) * 1000
    }

    func unloadModel() async {
        runtime = nil
        loadedModel = nil
        modelLoadMilliseconds = nil
    }

    func generate(request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceChunk, Error> {
        guard let runtime, loadedModel == request.model else { throw InferenceError.modelNotLoaded }
        let hasImage = request.messages.flatMap(\.parts).contains { if case .image = $0 { return true }; return false }
        if hasImage && !runtime.supportsVision {
            throw InferenceError.unsupportedModality("image")
        }
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try runtime.generate(request: request) { text in
                        continuation.yield(InferenceChunk(text: text))
                        return !Task.isCancelled
                    }
                    continuation.yield(InferenceChunk(text: "", finishReason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func capabilities() async -> BackendCapabilities {
        BackendCapabilities(text: true, image: runtime?.supportsVision ?? true, audio: false, streaming: true)
    }

    func metrics() async -> BackendMetrics {
        BackendMetrics(
            loadedModel: loadedModel,
            modelLoadMilliseconds: modelLoadMilliseconds,
            computeBackend: runtime == nil ? nil : "metal",
            multiTokenPredictionEnabled: false
        )
    }
}

enum LlamaError: Error, LocalizedError {
    case modelLoadFailed
    case contextInitFailed
    case projectorLoadFailed
    case imageDecodeFailed
    case tokenizeFailed(Int32)
    case promptTooLong(Int, Int)
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "llama.cpp could not load the GGUF model."
        case .contextInitFailed: return "llama.cpp could not create an inference context."
        case .projectorLoadFailed: return "llama.cpp could not load the multimodal projector (mmproj)."
        case .imageDecodeFailed: return "The image could not be decoded for the vision encoder."
        case let .tokenizeFailed(code): return "Prompt tokenization failed (\(code))."
        case let .promptTooLong(tokens, limit):
            return "The prompt needs \(tokens) tokens, but the context holds \(limit). Shorten it or raise the context length."
        case let .decodeFailed(code): return "llama.cpp decoding failed (\(code))."
        }
    }
}

/// Owns the llama.cpp model, context and optional mtmd context.
/// Only one generation runs at a time (InferenceService enforces this).
final class LlamaRuntime: @unchecked Sendable {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let multimodal: OpaquePointer?
    private let batchSize: Int32
    private let contextSize: Int

    var supportsVision: Bool { multimodal.map { mtmd_support_vision($0) } ?? false }

    private static let backendInit: Void = llama_backend_init()

    init(modelPath: String, projectorPath: String?, contextTokens: Int) throws {
        _ = Self.backendInit
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoadFailed
        }
        let threads = Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextTokens)
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.contextInitFailed
        }
        var multimodal: OpaquePointer?
        if let projectorPath {
            var mtmdParams = mtmd_context_params_default()
            mtmdParams.use_gpu = true
            mtmdParams.n_threads = threads
            mtmdParams.print_timings = false
            guard let created = mtmd_init_from_file(projectorPath, model, mtmdParams) else {
                llama_free(context)
                llama_model_free(model)
                throw LlamaError.projectorLoadFailed
            }
            multimodal = created
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.multimodal = multimodal
        self.batchSize = Int32(llama_n_batch(context))
        self.contextSize = Int(llama_n_ctx(context))
    }

    deinit {
        if let multimodal { mtmd_free(multimodal) }
        llama_free(context)
        llama_model_free(model)
    }

    /// Runs one completion. `emit` receives decoded text and returns false to stop early.
    func generate(request: InferenceRequest, emit: (String) -> Bool) throws {
        llama_memory_clear(llama_get_memory(context), true)
        let (prompt, images) = GemmaPromptFormatter.format(request.messages, mediaMarker: mediaMarker)

        var nPast: Int32 = 0
        if let multimodal {
            nPast = try evaluateMultimodal(prompt: prompt, images: images, multimodal: multimodal)
        } else {
            nPast = try evaluateText(prompt: prompt)
        }

        let sampler = Self.makeSampler(temperature: request.temperature)
        defer { llama_sampler_free(sampler) }
        var decoder = UTF8StreamDecoder()
        let budget = min(request.maxTokens, contextSize - Int(nPast))
        for _ in 0..<max(0, budget) {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            if let text = decoder.append(piece(for: token)), !text.isEmpty, !emit(text) { return }
            var next = token
            let status = llama_decode(context, llama_batch_get_one(&next, 1))
            if status != 0 { throw LlamaError.decodeFailed(status) }
        }
        if let rest = decoder.flush(), !rest.isEmpty { _ = emit(rest) }
    }

    private var mediaMarker: String {
        multimodal.flatMap { mtmd_get_marker($0) }.map { String(cString: $0) } ?? String(cString: mtmd_default_marker())
    }

    private func evaluateText(prompt: String) throws -> Int32 {
        let utf8Count = Int32(prompt.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
        let count = llama_tokenize(vocab, prompt, utf8Count, &tokens, Int32(tokens.count), true, true)
        guard count >= 0 else { throw LlamaError.tokenizeFailed(count) }
        guard Int(count) < contextSize else { throw LlamaError.promptTooLong(Int(count), contextSize) }
        var offset = 0
        while offset < Int(count) {
            let length = min(Int(batchSize), Int(count) - offset)
            let status = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + offset, Int32(length)))
            }
            if status != 0 { throw LlamaError.decodeFailed(status) }
            offset += length
        }
        return count
    }

    private func evaluateMultimodal(prompt: String, images: [Data], multimodal: OpaquePointer) throws -> Int32 {
        var bitmaps: [OpaquePointer?] = []
        defer { bitmaps.forEach { if let bitmap = $0 { mtmd_bitmap_free(bitmap) } } }
        for image in images {
            let wrapper = image.withUnsafeBytes { raw in
                mtmd_helper_bitmap_init_from_buf(
                    multimodal,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    raw.count,
                    false,
                    mtmd_helper_init_opt_default()
                )
            }
            if let video = wrapper.video_ctx { mtmd_helper_video_free(video) }
            guard let bitmap = wrapper.bitmap else { throw LlamaError.imageDecodeFailed }
            bitmaps.append(bitmap)
        }

        guard let chunks = mtmd_input_chunks_init() else { throw LlamaError.tokenizeFailed(-1) }
        defer { mtmd_input_chunks_free(chunks) }
        let status: Int32 = prompt.withCString { cString in
            var text = mtmd_input_text(text: cString, text_len: strlen(cString), add_special: true, parse_special: true)
            return bitmaps.withUnsafeBufferPointer { buffer in
                mtmd_tokenize(multimodal, chunks, &text, buffer.baseAddress, buffer.count)
            }
        }
        guard status == 0 else { throw LlamaError.tokenizeFailed(status) }
        let needed = mtmd_helper_get_n_tokens(chunks)
        guard needed < contextSize else { throw LlamaError.promptTooLong(needed, contextSize) }

        var newPast: llama_pos = 0
        let evaluated = mtmd_helper_eval_chunks(multimodal, context, chunks, 0, 0, batchSize, true, &newPast)
        guard evaluated == 0 else { throw LlamaError.decodeFailed(evaluated) }
        return newPast
    }

    private func piece(for token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(0, length))).map { UInt8(bitPattern: $0) }
    }

    private static func makeSampler(temperature: Double) -> UnsafeMutablePointer<llama_sampler> {
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(Float(temperature)))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        }
        return sampler
    }
}

/// Builds a Gemma 4 prompt, following the model's chat template for text and image turns.
/// Images are replaced by the mtmd media marker, in message order.
enum GemmaPromptFormatter {
    static func format(_ messages: [InferenceMessage], mediaMarker: String) -> (prompt: String, images: [Data]) {
        var prompt = ""
        var images: [Data] = []
        var remaining = messages[...]
        if let first = remaining.first, first.role == .system {
            prompt += "<|turn>system\n" + text(of: first).trimmingCharacters(in: .whitespacesAndNewlines) + "<turn|>\n"
            remaining = remaining.dropFirst()
        }
        for message in remaining {
            let role: String
            switch message.role {
            case .assistant: role = "model"
            case .system: role = "system"
            case .user, .tool: role = "user"
            }
            prompt += "<|turn>\(role)\n"
            for part in message.parts {
                switch part {
                case let .text(value):
                    prompt += value.trimmingCharacters(in: .whitespacesAndNewlines)
                case let .image(image):
                    prompt += "\n\n\(mediaMarker)\n\n"
                    images.append(image.data)
                case .audio:
                    prompt += "[Audio input was omitted by this API adapter.]"
                case let .tool(call):
                    prompt += "[Tool \(call.name): \(call.argumentsJSON)]"
                }
            }
            prompt += "<turn|>\n"
        }
        prompt += "<|turn>model\n"
        return (prompt, images)
    }

    private static func text(of message: InferenceMessage) -> String {
        message.parts.compactMap { part -> String? in
            if case let .text(value) = part { return value }
            return nil
        }.joined(separator: "\n")
    }
}

/// Token pieces can split a multi-byte UTF-8 character; emit only complete characters.
struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) -> String? {
        pending += bytes
        if let text = String(bytes: pending, encoding: .utf8) {
            pending.removeAll()
            return text
        }
        // An incomplete sequence is at most 3 bytes; anything longer is invalid data.
        if pending.count > 8 { return flush() }
        return nil
    }

    mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}
