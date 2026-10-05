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
        let parts = request.messages.flatMap(\.parts)
        if parts.contains(where: { if case .image = $0 { return true }; return false }) && !runtime.supportsVision {
            throw InferenceError.unsupportedModality("image")
        }
        if parts.contains(where: { if case .audio = $0 { return true }; return false }) && !runtime.supportsAudio {
            throw InferenceError.unsupportedModality("audio")
        }
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let result = try runtime.generate(request: request) { text in
                        continuation.yield(InferenceChunk(text: text))
                        return !Task.isCancelled
                    }
                    continuation.yield(InferenceChunk(
                        text: "",
                        finishReason: result.reachedLimit ? "length" : "stop",
                        usage: TokenUsage(
                            promptTokens: result.promptTokens,
                            completionTokens: result.completionTokens,
                            cachedTokens: result.reusedPositions
                        )
                    ))
                    continuation.finish()
                } catch let LlamaError.promptTooLong(tokens, limit) {
                    // A client can react to this (shorten the history), so it gets its own error type.
                    continuation.finish(throwing: InferenceError.contextLengthExceeded(promptTokens: tokens, contextTokens: limit))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func capabilities() async -> BackendCapabilities {
        BackendCapabilities(
            text: true, image: runtime?.supportsVision ?? true, audio: runtime?.supportsAudio ?? false, streaming: true
        )
    }

    func metrics() async -> BackendMetrics {
        BackendMetrics(
            loadedModel: loadedModel,
            modelLoadMilliseconds: modelLoadMilliseconds,
            computeBackend: runtime == nil ? nil : "metal",
            multiTokenPredictionEnabled: false,
            contextTokens: runtime?.contextSize
        )
    }
}

enum LlamaError: Error, LocalizedError {
    /// The load failures carry llama.cpp's own last warnings and errors, when it logged any.
    case modelLoadFailed(String?)
    case contextInitFailed(String?)
    case projectorLoadFailed(String?)
    case mediaDecodeFailed
    case tokenizeFailed(Int32)
    case promptTooLong(Int, Int)
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .modelLoadFailed(reason):
            return Self.describe("llama.cpp could not load the GGUF model.", reason)
        case let .contextInitFailed(reason):
            return Self.describe("llama.cpp could not create an inference context.", reason)
        case let .projectorLoadFailed(reason):
            return Self.describe("llama.cpp could not load the multimodal projector (mmproj).", reason)
        case .mediaDecodeFailed: return "The image or audio clip could not be decoded (images: JPEG/PNG; audio: WAV, MP3 or FLAC)."
        case let .tokenizeFailed(code): return "Prompt tokenization failed (\(code))."
        case let .promptTooLong(tokens, limit):
            return "The prompt needs \(tokens) tokens, but the context holds \(limit). Shorten it or raise the context length."
        case let .decodeFailed(code): return "llama.cpp decoding failed (\(code))."
        }
    }

    private static func describe(_ message: String, _ reason: String?) -> String {
        reason.map { "\(message) \($0)" } ?? message
    }
}

/// Keeps llama.cpp's most recent warnings and errors so a failed load can report its cause.
/// llama.cpp writes them only to stderr, which nobody sees on a device without a debugger.
enum LlamaLogCapture {
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static var pending = ""
    private static var pendingLevel = GGML_LOG_LEVEL_NONE
    private static let capacity = 8

    /// Routes llama.cpp and mtmd logging through the capture.
    static let install: Void = {
        let callback: ggml_log_callback = { level, text, _ in
            guard let text else { return }
            LlamaLogCapture.handle(level: level, text: text)
        }
        llama_log_set(callback, nil)
        mtmd_helper_log_set(callback, nil)
    }()

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
        pending = ""
    }

    /// The last captured warnings and errors, oldest first, or nil if there were none.
    static func summary() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty ? nil : String(lines.suffix(3).joined(separator: " | ").prefix(600))
    }

    private static func handle(level: ggml_log_level, text: UnsafePointer<CChar>) {
        lock.lock()
        defer { lock.unlock() }
        // GGML_LOG_LEVEL_CONT continues the previous message and keeps its level.
        if level.rawValue != GGML_LOG_LEVEL_CONT.rawValue { pendingLevel = level }
        // Debug messages include the prompt text, which must stay out of logs; everything else
        // still goes to stderr.
        guard pendingLevel.rawValue != GGML_LOG_LEVEL_DEBUG.rawValue else { return }
        fputs(text, stderr)
        let keep = pendingLevel.rawValue == GGML_LOG_LEVEL_WARN.rawValue
            || pendingLevel.rawValue == GGML_LOG_LEVEL_ERROR.rawValue
        guard keep else { return }
        pending += String(cString: text)
        while let newline = pending.firstIndex(of: "\n") {
            let line = pending[..<newline].trimmingCharacters(in: .whitespaces)
            pending = String(pending[pending.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
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
    let contextSize: Int
    /// What the KV cache holds, so a request that continues the previous conversation only evaluates
    /// what is new. `LLAMA_PROMPT_CACHE=0` or the launch argument `-llamaPromptCache 0` turns it off (to measure what it saves).
    private var promptCache = PromptCache()
    private let promptCacheEnabled = ProcessInfo.processInfo.environment["LLAMA_PROMPT_CACHE"] != "0"
        && UserDefaults.standard.string(forKey: "llamaPromptCache") != "0"
    private let chatTemplate: String?
    private let usesGemma4Template: Bool

    var supportsVision: Bool { multimodal.map { mtmd_support_vision($0) } ?? false }
    /// Audio needs a projector with an audio encoder (Gemma 4's mmproj has one).
    var supportsAudio: Bool { multimodal.map { mtmd_support_audio($0) } ?? false }

    private static let backendInit: Void = {
        _ = LlamaLogCapture.install
        llama_backend_init()
    }()

    init(modelPath: String, projectorPath: String?, contextTokens: Int) throws {
        _ = Self.backendInit
        LlamaLogCapture.reset()
        var modelParams = llama_model_default_params()
        // All layers on the GPU by default. A model that does not fit in the GPU's memory (Gemma 4 E4B on an
        // 8 GB iPhone) can keep some layers on the CPU: the launch argument `-llamaGpuLayers N` sets N.
        // A launch argument arrives as a string, so it is read as one and converted.
        let gpuLayerOverride = UserDefaults.standard.string(forKey: "llamaGpuLayers").flatMap { Int($0) }
        modelParams.n_gpu_layers = Int32(gpuLayerOverride ?? 999)
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.modelLoadFailed(LlamaLogCapture.summary())
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
            throw LlamaError.contextInitFailed(LlamaLogCapture.summary())
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
                throw LlamaError.projectorLoadFailed(LlamaLogCapture.summary())
            }
            multimodal = created
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.multimodal = multimodal
        self.batchSize = Int32(llama_n_batch(context))
        self.contextSize = Int(llama_n_ctx(context))
        self.chatTemplate = llama_model_chat_template(model, nil).map { String(cString: $0) }
        self.usesGemma4Template = Self.metadata(model, "general.architecture") == "gemma4"
    }

    private static func metadata(_ model: OpaquePointer, _ key: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard llama_model_meta_val_str(model, key, &buffer, buffer.count) >= 0 else { return nil }
        return String(cString: buffer)
    }

    /// Gemma 4's chat template is written out in `GemmaPromptFormatter`; every other model
    /// uses the template stored in its GGUF file.
    private func formatPrompt(_ messages: [InferenceMessage], enableThinking: Bool?) -> (prompt: String, media: [Data]) {
        if usesGemma4Template {
            return GemmaPromptFormatter.format(messages, mediaMarker: mediaMarker)
        }
        return TemplatePromptFormatter.format(
            messages, template: chatTemplate, mediaMarker: mediaMarker, enableThinking: enableThinking
        )
    }

    deinit {
        if let multimodal { mtmd_free(multimodal) }
        llama_free(context)
        llama_model_free(model)
    }

    struct GenerationResult {
        /// True when the output was cut off by the token limit instead of ending by itself.
        let reachedLimit: Bool
        let promptTokens: Int
        let completionTokens: Int
        /// Prompt positions that were already in the KV cache and did not have to be evaluated.
        let reusedPositions: Int
    }

    /// Runs one completion. `emit` receives decoded text and returns false to stop early.
    func generate(request: InferenceRequest, emit: (String) -> Bool) throws -> GenerationResult {
        let (prompt, media) = formatPrompt(request.messages, enableThinking: request.enableThinking)
        let evaluation = try evaluate(prompt: prompt, media: media)
        let nPast = evaluation.nextPosition

        let sampler = Self.makeSampler(temperature: request.temperature)
        defer { llama_sampler_free(sampler) }
        var decoder = UTF8StreamDecoder()
        let budget = min(request.maxTokens, contextSize - Int(nPast))
        var reachedLimit = true
        var generatedTokens: [Int32] = []
        let promptTokens = evaluation.promptTokens
        func finish(limit: Bool) -> GenerationResult {
            // The generated tokens are in the KV cache now, so the next turn can keep them.
            promptCache.store(prompt: evaluation.segments, generated: generatedTokens)
            return GenerationResult(
                reachedLimit: limit,
                promptTokens: promptTokens,
                completionTokens: generatedTokens.count,
                reusedPositions: evaluation.reusedPositions
            )
        }
        for _ in 0..<max(0, budget) {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                reachedLimit = false
                break
            }
            generatedTokens.append(token)
            if let text = decoder.append(piece(for: token)), !text.isEmpty, !emit(text) {
                // Stopped early: the last token was sampled but not decoded, so it is not in the cache.
                generatedTokens.removeLast()
                return finish(limit: false)
            }
            var next = token
            let status = llama_decode(context, llama_batch_get_one(&next, 1))
            if status != 0 {
                promptCache.reset()
                throw LlamaError.decodeFailed(status)
            }
        }
        if let rest = decoder.flush(), !rest.isEmpty { _ = emit(rest) }
        return finish(limit: reachedLimit)
    }

    struct Evaluation {
        /// The prompt as segments, in the form the cache compares.
        let segments: [PromptSegment]
        let nextPosition: Int32
        let promptTokens: Int
        let reusedPositions: Int
    }

    /// Evaluates the prompt, skipping the start that the KV cache already holds.
    private func evaluate(prompt: String, media: [Data]) throws -> Evaluation {
        let memory = llama_get_memory(context)
        let chunks = try tokenize(prompt: prompt, media: media)
        defer { if let chunks = chunks.handle { mtmd_input_chunks_free(chunks) } }
        let segments = chunks.segments
        let needed = segments.reduce(0) { $0 + $1.tokenCount }
        guard needed < contextSize else { throw LlamaError.promptTooLong(needed, contextSize) }

        let reuse = promptCacheEnabled ? promptCache.reuse(for: segments) : PromptCache.Reuse(keptPositions: 0, resumeSegment: 0, resumeTokenOffset: 0)
        if reuse.keptPositions == 0 {
            llama_memory_clear(memory, true)
        } else if !llama_memory_seq_rm(memory, 0, llama_pos(reuse.keptPositions), -1) {
            // The cache could not drop the tail (a sliding-window cache can refuse); start over.
            llama_memory_clear(memory, true)
            return try evaluateFromStart(chunks: chunks, segments: segments)
        }

        var position = llama_pos(reuse.keptPositions)
        for index in reuse.resumeSegment..<segments.count {
            let isLast = index == segments.count - 1
            switch segments[index] {
            case let .text(tokens):
                let offset = index == reuse.resumeSegment ? reuse.resumeTokenOffset : 0
                position = try decodeText(Array(tokens[offset...]), from: position, wantLogits: isLast)
            case .media:
                guard let multimodal, let chunk = chunks.chunk(at: index) else { throw LlamaError.decodeFailed(-1) }
                var newPosition: llama_pos = position
                let status = mtmd_helper_eval_chunk_single(multimodal, context, chunk, position, 0, batchSize, isLast, &newPosition)
                guard status == 0 else { promptCache.reset(); throw LlamaError.decodeFailed(status) }
                position = newPosition
            }
        }
        return Evaluation(segments: segments, nextPosition: position, promptTokens: needed, reusedPositions: reuse.keptPositions)
    }

    private func evaluateFromStart(chunks: TokenizedPrompt, segments: [PromptSegment]) throws -> Evaluation {
        var position: llama_pos = 0
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            switch segment {
            case let .text(tokens):
                position = try decodeText(tokens, from: position, wantLogits: isLast)
            case .media:
                guard let multimodal, let chunk = chunks.chunk(at: index) else { throw LlamaError.decodeFailed(-1) }
                var newPosition: llama_pos = position
                let status = mtmd_helper_eval_chunk_single(multimodal, context, chunk, position, 0, batchSize, isLast, &newPosition)
                guard status == 0 else { promptCache.reset(); throw LlamaError.decodeFailed(status) }
                position = newPosition
            }
        }
        return Evaluation(segments: segments, nextPosition: position, promptTokens: segments.reduce(0) { $0 + $1.tokenCount }, reusedPositions: 0)
    }

    private func decodeText(_ tokens: [Int32], from start: llama_pos, wantLogits: Bool) throws -> llama_pos {
        var position = start
        var offset = 0
        var batchTokens = tokens
        while offset < batchTokens.count {
            let length = min(Int(batchSize), batchTokens.count - offset)
            var batch = batchTokens.withUnsafeMutableBufferPointer { buffer in
                llama_batch_get_one(buffer.baseAddress! + offset, Int32(length))
            }
            // llama_batch_get_one numbers positions from the cache's end; set them explicitly so a
            // resumed text run lands where it should.
            let positions = (0..<length).map { position + llama_pos($0) }
            var positionsCopy = positions
            let status: Int32 = positionsCopy.withUnsafeMutableBufferPointer { positionBuffer in
                batch.pos = positionBuffer.baseAddress
                return batchTokens.withUnsafeMutableBufferPointer { tokenBuffer in
                    batch.token = tokenBuffer.baseAddress! + offset
                    return llama_decode(context, batch)
                }
            }
            if status != 0 { promptCache.reset(); throw LlamaError.decodeFailed(status) }
            position += llama_pos(length)
            offset += length
        }
        return position
    }

    private var mediaMarker: String {
        multimodal.flatMap { mtmd_get_marker($0) }.map { String(cString: $0) } ?? String(cString: mtmd_default_marker())
    }

    /// The prompt split into text runs and media, with the mtmd chunks kept alive for evaluation.
    struct TokenizedPrompt {
        let handle: OpaquePointer?
        let segments: [PromptSegment]

        func chunk(at index: Int) -> OpaquePointer? {
            guard let handle else { return nil }
            return mtmd_input_chunks_get(handle, index)
        }
    }

    /// `media` holds image and audio files in prompt order; mtmd tells them apart by their bytes.
    private func tokenize(prompt: String, media: [Data]) throws -> TokenizedPrompt {
        guard let multimodal else {
            // Text only: one run of tokens.
            let utf8Count = Int32(prompt.utf8.count)
            var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 16)
            let count = llama_tokenize(vocab, prompt, utf8Count, &tokens, Int32(tokens.count), true, true)
            guard count >= 0 else { throw LlamaError.tokenizeFailed(count) }
            return TokenizedPrompt(handle: nil, segments: [.text(Array(tokens.prefix(Int(count))))])
        }
        var bitmaps: [OpaquePointer?] = []
        defer { bitmaps.forEach { if let bitmap = $0 { mtmd_bitmap_free(bitmap) } } }
        for item in media {
            let wrapper = item.withUnsafeBytes { raw in
                mtmd_helper_bitmap_init_from_buf(
                    multimodal,
                    raw.bindMemory(to: UInt8.self).baseAddress,
                    raw.count,
                    false
                )
            }
            if let video = wrapper.video_ctx { mtmd_helper_video_free(video) }
            guard let bitmap = wrapper.bitmap else { throw LlamaError.mediaDecodeFailed }
            bitmaps.append(bitmap)
        }

        guard let chunks = mtmd_input_chunks_init() else { throw LlamaError.tokenizeFailed(-1) }
        let status: Int32 = prompt.withCString { cString in
            var text = mtmd_input_text(text: cString, text_len: strlen(cString), add_special: true, parse_special: true)
            return bitmaps.withUnsafeMutableBufferPointer { buffer in
                mtmd_tokenize(multimodal, chunks, &text, buffer.baseAddress, buffer.count)
            }
        }
        guard status == 0 else {
            mtmd_input_chunks_free(chunks)
            throw LlamaError.tokenizeFailed(status)
        }
        var segments: [PromptSegment] = []
        for index in 0..<mtmd_input_chunks_size(chunks) {
            guard let chunk = mtmd_input_chunks_get(chunks, index) else { continue }
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var count = 0
                let pointer = mtmd_input_chunk_get_tokens_text(chunk, &count)
                segments.append(.text(pointer.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []))
            } else {
                let identifier = mtmd_input_chunk_get_id(chunk).map { String(cString: $0) } ?? ""
                segments.append(.media(
                    id: identifier,
                    tokens: Int(mtmd_input_chunk_get_n_tokens(chunk)),
                    positions: Int(mtmd_input_chunk_get_n_pos(chunk))
                ))
            }
        }
        return TokenizedPrompt(handle: chunks, segments: segments)
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
