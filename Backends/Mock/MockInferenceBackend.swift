import Foundation

struct MockInferenceBackend: InferenceBackend {
    let identifier = "mock"

    func loadModel(configuration: ModelConfiguration) async throws {}

    func unloadModel() async {}

    func generate(request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceChunk, Error> {
        let userText = request.messages
            .filter { $0.role == .user }
            .flatMap(\.parts)
            .compactMap { part -> String? in
                if case let .text(text) = part { return text }
                return nil
            }
            .joined(separator: " ")
        let hasImage = request.messages.flatMap(\.parts).contains {
            if case .image = $0 { return true }
            return false
        }
        let response = hasImage
            ? "Mock backend received an image. Image understanding is not enabled in this development backend."
            : "Mock response: \(userText.isEmpty ? "Send a text message to exercise the API." : userText)"
        let pieces = response.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        return AsyncThrowingStream { continuation in
            let task = Task {
                for (index, piece) in pieces.enumerated() {
                    if Task.isCancelled {
                        continuation.finish(throwing: InferenceError.generationCancelled)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(18))
                    continuation.yield(InferenceChunk(text: piece + (index == pieces.count - 1 ? "" : " ")))
                }
                continuation.yield(InferenceChunk(text: "", finishReason: "stop"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func capabilities() async -> BackendCapabilities {
        BackendCapabilities(text: true, image: false, audio: false, streaming: true)
    }

    func metrics() async -> BackendMetrics {
        BackendMetrics(loadedModel: "mock-echo", modelLoadMilliseconds: 0, computeBackend: "mock", multiTokenPredictionEnabled: false)
    }
}
