import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var serverRunning = false
    @Published private(set) var serverStarting = false
    @Published private(set) var modelLoading = false
    @Published private(set) var apiKey = ""
    @Published private(set) var installedModels: [InstalledModel] = []
    @Published private(set) var metricsSnapshot: MetricsSnapshot?
    @Published private(set) var logEntries: [LogEntry] = []
    @Published private(set) var lastError: String?
    @Published var port: Int
    @Published private(set) var allowLAN: Bool
    @Published private(set) var defaultMaxTokens: Int
    @Published private(set) var temperature: Double
    @Published private(set) var contextTokens: Int
    @Published private(set) var multiTokenPredictionEnabled: Bool
    @Published private(set) var benchmarkRunning = false
    @Published private(set) var supportsVision = false

    private let keyStore = APIKeyStore()
    private let modelManager = ModelManager()
    private let metrics = MetricsService()
    private let logs = LogService()
    private var inferenceDefaults: InferenceDefaults
    private lazy var inference = InferenceService(metrics: metrics, logs: logs)
    private var server: HTTPServer?
    private var memoryWarningObserver: NSObjectProtocol? = nil

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: "httpPort")
        let savedContextTokens = UserDefaults.standard.integer(forKey: "contextTokens")
        let configuredContextTokens = [1024, 2048, 4096, 8192].contains(savedContextTokens) ? savedContextTokens : InferenceDefaults.standard.contextTokens
        let savedMaxTokens = UserDefaults.standard.integer(forKey: "defaultMaxTokens")
        let configuredMaxTokens = (1...configuredContextTokens).contains(savedMaxTokens) ? savedMaxTokens : min(InferenceDefaults.standard.maxTokens, configuredContextTokens)
        let savedTemperature = UserDefaults.standard.object(forKey: "temperature") as? Double
        let configuredTemperature = savedTemperature.map { (0...2).contains($0) ? $0 : InferenceDefaults.standard.temperature } ?? InferenceDefaults.standard.temperature
        let configuredMTP = UserDefaults.standard.bool(forKey: "multiTokenPredictionEnabled")

        port = (1024...65535).contains(savedPort) ? savedPort : 8080
        allowLAN = UserDefaults.standard.bool(forKey: "allowLAN")
        contextTokens = configuredContextTokens
        defaultMaxTokens = configuredMaxTokens
        temperature = configuredTemperature
        multiTokenPredictionEnabled = configuredMTP
        inferenceDefaults = InferenceDefaults(maxTokens: configuredMaxTokens, temperature: configuredTemperature, contextTokens: configuredContextTokens)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleMemoryWarning()
            }
        }
    }

    var endpoint: String { "http://127.0.0.1:\(port)" }

    func startServer() async {
        guard server == nil, !serverStarting else { return }
        serverStarting = true
        defer { serverStarting = false }
        do {
            apiKey = try keyStore.loadOrCreate()
            let service = HTTPServer(
                port: UInt16(port),
                apiKey: apiKey,
                allowLAN: allowLAN,
                inference: inference,
                inferenceDefaults: inferenceDefaults,
                metrics: metrics,
                logs: logs
            )
            try await service.start()
            server = service
            serverRunning = true
            UIApplication.shared.isIdleTimerDisabled = true
            lastError = nil
        } catch {
            serverRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
            lastError = error.localizedDescription
            await logs.write(.error, event: "http_server_start_failed", details: error.localizedDescription)
        }
    }

    func stopServer() async {
        guard let server else { return }
        await server.stop()
        self.server = nil
        serverRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func applyPort(_ newPort: Int) async {
        guard (1024...65535).contains(newPort) else {
            lastError = "Port must be between 1024 and 65535."
            return
        }
        port = newPort
        UserDefaults.standard.set(newPort, forKey: "httpPort")
        await restartServer()
    }

    func setLANEnabled(_ enabled: Bool) async {
        allowLAN = enabled
        UserDefaults.standard.set(enabled, forKey: "allowLAN")
        await restartServer()
    }

    func regenerateAPIKey() async {
        do {
            apiKey = try keyStore.regenerate()
            await logs.write(.warning, event: "api_key_regenerated")
            await restartServer()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        installedModels = await modelManager.list()
        metricsSnapshot = await metrics.snapshot()
        let active = await inference.activeModel()
        let capabilities = await inference.capabilities()
        supportsVision = active.loaded && capabilities.image
        logEntries = await logs.list()
        if apiKey.isEmpty { apiKey = (try? keyStore.loadOrCreate()) ?? "" }
    }

    func importModels(from urls: [URL]) async {
        do {
            for url in urls { _ = try await modelManager.importModel(from: url) }
            await logs.write(.info, event: "models_imported", details: "count=\(urls.count)")
            lastError = nil
            await refresh()
        } catch {
            lastError = "Model import failed: \(error.localizedDescription)"
            await logs.write(.error, event: "model_import_failed", details: error.localizedDescription)
        }
    }

    func loadModel(_ id: String) async {
        guard !modelLoading, !benchmarkRunning else { return }
        modelLoading = true
        defer { modelLoading = false }
        guard !(await inference.hasActiveGeneration()) else {
            lastError = "Wait for the active inference request to finish before loading a model."
            return
        }
        guard let model = await modelManager.model(id: id) else {
            lastError = "The selected model is no longer installed."
            return
        }
        do {
            guard try await modelManager.verifyModel(id: id) else {
                throw InferenceError.backendUnavailable("The model file is missing or its SHA-256 no longer matches the registry.")
            }
            try await inference.loadImportedModel(model, contextTokens: contextTokens, multiTokenPredictionEnabled: multiTokenPredictionEnabled)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            await logs.write(.error, event: "model_load_failed", details: "model=\(id) error=\(error.localizedDescription)")
        }
        await refresh()
    }

    func unloadModel() async {
        guard !modelLoading, !benchmarkRunning else { return }
        modelLoading = true
        defer { modelLoading = false }
        guard !(await inference.hasActiveGeneration()) else {
            lastError = "Wait for the active inference request to finish before unloading the model."
            return
        }
        do {
            try await inference.unloadModel()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeModel(_ id: String) async {
        guard !modelLoading, !benchmarkRunning else { return }
        modelLoading = true
        defer { modelLoading = false }
        guard !(await inference.hasActiveGeneration()) else {
            lastError = "Wait for the active inference request to finish before deleting a model."
            return
        }
        do {
            let active = await inference.activeModel()
            if active.id == id {
                try await inference.unloadModel()
            }
            try await modelManager.removeModel(id: id)
            await logs.write(.info, event: "model_removed", details: "model=\(id)")
            await refresh()
        } catch {
            lastError = "Could not remove model: \(error.localizedDescription)"
        }
    }

    func clearVisibleError() { lastError = nil }

    func reportError(_ message: String) { lastError = message }

    func runTextBenchmark() async {
        await runBenchmark(text: "Write a concise, two-sentence explanation of why local inference can reduce PC GPU memory use.", image: nil)
    }

    func runVisionBenchmark() async {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let image = renderer.image { context in
            let drawing = context.cgContext
            drawing.setFillColor(UIColor.white.cgColor)
            drawing.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            drawing.setFillColor(UIColor.systemBlue.cgColor)
            drawing.fill(CGRect(x: 32, y: 48, width: 76, height: 76))
            drawing.setFillColor(UIColor.systemRed.cgColor)
            drawing.fillEllipse(in: CGRect(x: 142, y: 124, width: 78, height: 78))
        }
        guard let data = image.pngData() else {
            lastError = "Could not create the built-in vision benchmark image."
            return
        }
        await runBenchmark(text: "Describe the colored shapes in this image.", image: ImageInput(data: data, mimeType: "image/png"))
    }

    func applyInferenceDefaults(maxTokens: Int, temperature: Double, contextTokens: Int, multiTokenPredictionEnabled: Bool) async {
        guard !modelLoading, !benchmarkRunning else {
            lastError = "Wait for the current model operation to finish before applying inference settings."
            return
        }
        modelLoading = true
        defer { modelLoading = false }
        guard !(await inference.hasActiveGeneration()) else {
            lastError = "Wait for the active inference request to finish before applying inference settings."
            return
        }
        guard (1...8192).contains(maxTokens), temperature.isFinite, (0...2).contains(temperature),
              [1024, 2048, 4096, 8192].contains(contextTokens), maxTokens <= contextTokens else {
            lastError = "Output tokens must fit within the context limit; temperature must be between 0 and 2."
            return
        }

        let previousContext = self.contextTokens
        let active = await inference.activeModel()
        let shouldReloadModel = (previousContext != contextTokens || self.multiTokenPredictionEnabled != multiTokenPredictionEnabled)
            && active.loaded && active.backend == "litert-lm"
        let shouldRestart = server != nil
        if shouldRestart { await stopServer() }

        self.defaultMaxTokens = maxTokens
        self.temperature = temperature
        self.contextTokens = contextTokens
        self.multiTokenPredictionEnabled = multiTokenPredictionEnabled
        inferenceDefaults = InferenceDefaults(maxTokens: maxTokens, temperature: temperature, contextTokens: contextTokens)
        UserDefaults.standard.set(maxTokens, forKey: "defaultMaxTokens")
        UserDefaults.standard.set(temperature, forKey: "temperature")
        UserDefaults.standard.set(contextTokens, forKey: "contextTokens")
        UserDefaults.standard.set(multiTokenPredictionEnabled, forKey: "multiTokenPredictionEnabled")

        if shouldReloadModel, let id = active.id {
            guard let model = await modelManager.model(id: id) else {
                lastError = "The loaded model is missing from the model registry. It was unloaded when inference settings changed."
                if shouldRestart { await startServer() }
                await refresh()
                return
            }
            do {
                try await inference.unloadModel()
                guard try await modelManager.verifyModel(id: id) else {
                    throw InferenceError.backendUnavailable("The model file is missing or its SHA-256 no longer matches the registry.")
                }
                try await inference.loadImportedModel(model, contextTokens: contextTokens, multiTokenPredictionEnabled: multiTokenPredictionEnabled)
                lastError = nil
            } catch {
                lastError = "Model reload failed after changing the context limit: \(error.localizedDescription)"
                await logs.write(.error, event: "model_reload_failed", details: "model=\(id) error=\(error.localizedDescription)")
            }
        }

        if shouldRestart { await startServer() }
        await refresh()
    }

    private func restartServer() async {
        let shouldRestart = server != nil
        await stopServer()
        if shouldRestart { await startServer() }
    }

    private func runBenchmark(text: String, image: ImageInput?) async {
        guard !benchmarkRunning, !modelLoading else { return }
        benchmarkRunning = true
        defer { benchmarkRunning = false }
        let active = await inference.activeModel()
        guard active.loaded, let modelID = active.id else {
            lastError = "Load a model before running a benchmark."
            return
        }
        var parts: [MessagePart] = [.text(text)]
        if let image { parts.append(.image(image)) }
        let request = InferenceRequest(
            id: "benchmark-\(UUID().uuidString)",
            model: modelID,
            messages: [InferenceMessage(role: .user, parts: parts)],
            maxTokens: min(128, contextTokens),
            temperature: 0.1
        )
        do {
            let stream = try await inference.generate(request)
            for try await _ in stream { }
            lastError = nil
            await logs.write(.info, event: "benchmark_completed", requestID: request.id, details: image == nil ? "kind=text" : "kind=vision")
        } catch {
            lastError = "Benchmark failed: \(error.localizedDescription)"
            await logs.write(.error, event: "benchmark_failed", requestID: request.id, details: error.localizedDescription)
        }
        await refresh()
    }

    private func handleMemoryWarning() async {
        await logs.write(.warning, event: "memory_warning", details: "application_received_memory_warning")
        guard !modelLoading else { return }
        modelLoading = true
        defer { modelLoading = false }
        do {
            try await inference.unloadModel()
            await logs.write(.warning, event: "model_unloaded_for_memory_pressure")
            await refresh()
        } catch {
            await logs.write(.warning, event: "model_unload_deferred", details: "inference_in_progress")
        }
    }
}
