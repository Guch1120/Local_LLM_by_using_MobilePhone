import Foundation

actor InferenceService {
    private var backend: any InferenceBackend = MockInferenceBackend()
    private var modelID = "mock-echo"
    private var loaded = true
    private var generationInProgress = false
    private let metrics: MetricsService
    private let logs: LogService

    init(metrics: MetricsService, logs: LogService) {
        self.metrics = metrics
        self.logs = logs
    }

    func activeModel() -> (id: String?, backend: String, loaded: Bool) {
        (loaded ? modelID : nil, backend.identifier, loaded)
    }

    func loadImportedModel(_ model: InstalledModel, contextTokens: Int, multiTokenPredictionEnabled: Bool) async throws {
        guard !generationInProgress else { throw InferenceError.requestInProgress }
        loaded = false
        await metrics.setModel(loaded: false, model: nil, backend: backend.identifier, loadMilliseconds: nil)
        await backend.unloadModel()
        let configuration = ModelConfiguration(
            id: model.id,
            name: model.name,
            fileURL: model.fileURL,
            sha256: model.sha256,
            contextTokens: contextTokens,
            multiTokenPredictionEnabled: multiTokenPredictionEnabled,
            projectorURL: model.projectorURL
        )
        let candidate: any InferenceBackend = model.backend == "llama.cpp" ? LlamaCppBackend() : LiteRTGemmaBackend()
        let start = Date()
        try await candidate.loadModel(configuration: configuration)
        backend = candidate
        modelID = model.id
        loaded = true
        let elapsed = Date().timeIntervalSince(start) * 1000
        await metrics.setModel(loaded: true, model: modelID, backend: backend.identifier, loadMilliseconds: elapsed)
        await logs.write(.info, event: "model_loaded", details: "backend=\(backend.identifier) model=\(modelID)")
    }

    func unloadModel() async throws {
        guard !generationInProgress else { throw InferenceError.requestInProgress }
        loaded = false
        await metrics.setModel(loaded: false, model: nil, backend: backend.identifier, loadMilliseconds: nil)
        await backend.unloadModel()
        await logs.write(.info, event: "model_unloaded")
    }

    func generate(_ request: InferenceRequest) async throws -> AsyncThrowingStream<InferenceChunk, Error> {
        guard loaded else { throw InferenceError.modelNotLoaded }
        guard request.model == modelID else { throw InferenceError.modelNotFound(request.model) }
        guard !generationInProgress else {
            await metrics.beginRequest()
            await metrics.finishRequest(promptTokens: 0, generatedTokens: 0, ttftMilliseconds: 0, totalLatencyMilliseconds: 0, failed: true)
            await logs.write(.warning, event: "inference_rejected_busy", requestID: request.id)
            throw InferenceError.requestInProgress
        }
        let capabilities = await backend.capabilities()
        if request.messages.flatMap(\.parts).contains(where: { if case .image = $0 { return true }; return false }) && !capabilities.image {
            throw InferenceError.unsupportedModality("image")
        }
        if request.messages.flatMap(\.parts).contains(where: { if case .audio = $0 { return true }; return false }) && !capabilities.audio {
            throw InferenceError.unsupportedModality("audio")
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            let state = MetricsService.thermalState
            await logs.write(.warning, event: "inference_rejected_thermal", requestID: request.id, details: state)
            throw InferenceError.thermalLimit(state)
        default:
            break
        }

        let promptTokens = request.messages
            .flatMap(\.parts)
            .compactMap { part -> String? in if case let .text(value) = part { return value }; return nil }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).count
        let generationStartedAt = Date()
        generationInProgress = true
        await metrics.beginRequest()
        await logs.write(.info, event: "inference_started", requestID: request.id, details: "backend=\(backend.identifier)")

        let stream: AsyncThrowingStream<InferenceChunk, Error>
        do {
            stream = try await backend.generate(request: request)
        } catch {
            await finishGeneration(
                requestID: request.id,
                promptTokens: promptTokens,
                generatedTokens: 0,
                ttftMilliseconds: 0,
                totalLatencyMilliseconds: 0,
                failed: true
            )
            throw error
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var firstTokenAt: Date?
                var generatedTokens = 0
                var failed = false
                do {
                    for try await chunk in stream {
                        if !chunk.text.isEmpty {
                            firstTokenAt = firstTokenAt ?? Date()
                            generatedTokens += chunk.text.split(whereSeparator: \.isWhitespace).count
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    failed = true
                    continuation.finish(throwing: error)
                }
                let end = Date()
                let latency = end.timeIntervalSince(generationStartedAt) * 1000
                let ttft = firstTokenAt.map { $0.timeIntervalSince(generationStartedAt) * 1000 } ?? latency
                await self.finishGeneration(
                    requestID: request.id,
                    promptTokens: promptTokens,
                    generatedTokens: generatedTokens,
                    ttftMilliseconds: ttft,
                    totalLatencyMilliseconds: latency,
                    failed: failed
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func capabilities() async -> BackendCapabilities { await backend.capabilities() }

    func modelList() -> [[String: String]] {
        loaded ? [["id": modelID, "object": "model", "owned_by": "local"]] : []
    }

    func backendMetrics() async -> BackendMetrics { await backend.metrics() }

    func hasActiveGeneration() -> Bool { generationInProgress }

    private func finishGeneration(
        requestID: String,
        promptTokens: Int,
        generatedTokens: Int,
        ttftMilliseconds: Double,
        totalLatencyMilliseconds: Double,
        failed: Bool
    ) async {
        generationInProgress = false
        await metrics.finishRequest(
            promptTokens: promptTokens,
            generatedTokens: generatedTokens,
            ttftMilliseconds: ttftMilliseconds,
            totalLatencyMilliseconds: totalLatencyMilliseconds,
            failed: failed
        )
        await logs.write(
            failed ? .error : .info,
            event: failed ? "inference_failed" : "inference_completed",
            requestID: requestID,
            details: "latency_ms=\(Int(totalLatencyMilliseconds)) generated_tokens=\(generatedTokens)"
        )
    }
}
