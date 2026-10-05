import Foundation

struct InferenceDefaults: Sendable, Equatable {
    let maxTokens: Int
    let temperature: Double
    let contextTokens: Int

    static let standard = InferenceDefaults(maxTokens: 512, temperature: 0.7, contextTokens: 4096)

    /// The context sizes Settings offers. The model supports far more (Gemma 4 E2B: 131,072); the cap is what
    /// the phone's memory and speed allow (see SPEC.md, "Context window").
    static let contextChoices = [1024, 2048, 4096, 8192, 16384, 32768, 65536]
}

enum MessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

struct ToolInvocation: Codable, Sendable {
    let name: String
    let argumentsJSON: String
}

enum MessagePart: Sendable {
    case text(String)
    case image(ImageInput)
    case audio(Data, mimeType: String)
    case tool(ToolInvocation)
}

struct ImageInput: Sendable {
    let data: Data
    let mimeType: String
}

struct InferenceMessage: Sendable {
    let role: MessageRole
    let parts: [MessagePart]
}

struct InferenceRequest: Sendable {
    let id: String
    let model: String
    let messages: [InferenceMessage]
    let maxTokens: Int
    let temperature: Double
    /// `chat_template_kwargs.enable_thinking` of the request. nil leaves the model's own default;
    /// false asks a model that thinks before it answers (Qwen3.5) to answer at once.
    var enableThinking: Bool?
    /// `logprobs` / `top_logprobs` of the request: how many of the most likely tokens to report at every
    /// generated position. nil reports nothing, which keeps the normal path free of the extra work.
    var topLogprobs: Int?
}

/// Token counts measured by the backend's tokenizer (images count as the tokens they expand to).
struct TokenUsage: Sendable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    /// Prompt tokens that were already in the KV cache from the previous request and were not
    /// evaluated again (OpenAI's `prompt_tokens_details.cached_tokens`).
    var cachedTokens = 0
    var totalTokens: Int { promptTokens + completionTokens }
}

/// The probability the model gave to one token, with its most likely alternatives.
struct TokenLogprob: Sendable, Equatable {
    struct Candidate: Sendable, Equatable {
        let token: String
        let logprob: Double
    }

    let token: String
    let logprob: Double
    let top: [Candidate]
}

struct InferenceChunk: Sendable {
    let text: String
    let finishReason: String?
    /// Set on the final chunk by backends that can count tokens exactly.
    let usage: TokenUsage?
    /// Set when the request asked for `top_logprobs` and the backend can report them.
    let logprob: TokenLogprob?

    init(text: String, finishReason: String? = nil, usage: TokenUsage? = nil, logprob: TokenLogprob? = nil) {
        self.text = text
        self.finishReason = finishReason
        self.usage = usage
        self.logprob = logprob
    }
}

struct ModelConfiguration: Sendable {
    let id: String
    let name: String
    let fileURL: URL
    let sha256: String
    let contextTokens: Int
    let multiTokenPredictionEnabled: Bool
    var projectorURL: URL?
}

enum InferenceError: Error, LocalizedError, Sendable {
    case modelNotLoaded
    case modelNotFound(String)
    case unsupportedModality(String)
    case backendUnavailable(String)
    case requestInProgress
    case outOfMemory
    case thermalLimit(String)
    case contextLengthExceeded(promptTokens: Int, contextTokens: Int)
    case generationCancelled

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "No inference model is loaded."
        case let .modelNotFound(id):
            return "Model '\(id)' is not installed."
        case let .unsupportedModality(modality):
            return "The active backend does not support \(modality) input."
        case let .backendUnavailable(message):
            return message
        case .requestInProgress:
            return "Another inference request is already running. Try again when it finishes."
        case .outOfMemory:
            return "The device does not have enough memory to complete this request."
        case let .thermalLimit(state):
            return "Inference is paused because the device thermal state is \(state)."
        case let .contextLengthExceeded(promptTokens, contextTokens):
            return "The prompt needs \(promptTokens) tokens, but the context holds \(contextTokens). "
                + "Shorten it or raise the context length."
        case .generationCancelled:
            return "Generation was cancelled."
        }
    }
}
