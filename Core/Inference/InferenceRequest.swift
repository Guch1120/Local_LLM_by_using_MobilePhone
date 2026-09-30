import Foundation

struct InferenceDefaults: Sendable, Equatable {
    let maxTokens: Int
    let temperature: Double
    let contextTokens: Int

    static let standard = InferenceDefaults(maxTokens: 512, temperature: 0.7, contextTokens: 4096)
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
}

/// Token counts measured by the backend's tokenizer (images count as the tokens they expand to).
struct TokenUsage: Sendable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    var totalTokens: Int { promptTokens + completionTokens }
}

struct InferenceChunk: Sendable {
    let text: String
    let finishReason: String?
    /// Set on the final chunk by backends that can count tokens exactly.
    let usage: TokenUsage?

    init(text: String, finishReason: String? = nil, usage: TokenUsage? = nil) {
        self.text = text
        self.finishReason = finishReason
        self.usage = usage
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
