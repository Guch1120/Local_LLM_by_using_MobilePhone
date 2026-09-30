import Foundation

struct BackendCapabilities: Sendable {
    let text: Bool
    let image: Bool
    let audio: Bool
    let streaming: Bool
}

struct BackendMetrics: Sendable {
    let loadedModel: String?
    let modelLoadMilliseconds: Double?
    let computeBackend: String?
    let multiTokenPredictionEnabled: Bool
    /// Prompt and reply together must fit in this many tokens; nil when no model is loaded.
    var contextTokens: Int?
}

protocol InferenceBackend: Sendable {
    var identifier: String { get }

    func loadModel(configuration: ModelConfiguration) async throws
    func unloadModel() async
    func generate(request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceChunk, Error>
    func capabilities() async -> BackendCapabilities
    func metrics() async -> BackendMetrics
}
