import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var serverRunning = false
    @Published private(set) var serverStarting = false
    @Published private(set) var modelLoading = false
    @Published private(set) var modelImporting = false
    @Published private(set) var apiKey = ""
    @Published private(set) var installedModels: [InstalledModel] = []
    @Published private(set) var metricsSnapshot: MetricsSnapshot?
    @Published private(set) var logEntries: [LogEntry] = []
    @Published private(set) var lastError: String? {
        didSet {
            guard let lastError, lastError != oldValue else { return }
            Task { await logs.write(.error, event: "app_error", details: lastError) }
        }
    }
    @Published private(set) var logPersistenceStatus: LogPersistenceStatus?
    @Published var port: Int
    @Published private(set) var allowLAN: Bool
    @Published private(set) var defaultMaxTokens: Int
    @Published private(set) var temperature: Double
    @Published private(set) var contextTokens: Int
    @Published private(set) var multiTokenPredictionEnabled: Bool
    @Published private(set) var benchmarkRunning = false
    @Published private(set) var supportsVision = false
    @Published private(set) var downloads: [ModelDownload] = []
    @Published private(set) var hasHuggingFaceToken = false
    /// The request that is running or ran last, for the live view. Kept in memory only.
    @Published private(set) var liveRequest: LiveRequest?

    private let keyStore = APIKeyStore()
    private let huggingFaceTokenStore = HuggingFaceTokenStore()
    private let downloader = ModelDownloader()
    private let modelManager = ModelManager()
    private let metrics = MetricsService()
    private let logs: LogService
    private var inferenceDefaults: InferenceDefaults
    private lazy var inference = InferenceService(metrics: metrics, logs: logs)
    private var server: HTTPServer?
    private var memoryWarningObserver: NSObjectProtocol? = nil
    private var debugSessionID = UUID().uuidString
    private var hasCheckedPreviousSession = false
    private var appIsActive = false
    private var observedThermalState: String?

    private static let foregroundSessionKey = "diagnostics.foreground_session_active"
    private static let lastLoadedModelKey = "lastLoadedModelID"
    private static let autoLoadInProgressKey = "autoLoadInProgress"
    private var hasAttemptedAutoLoad = false

    init() {
        logs = LogService(persistenceURL: Self.diagnosticsLogURL())
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
        hasHuggingFaceToken = huggingFaceTokenStore.load() != nil
        // A stream keeps the events in order on their way to the main actor.
        let (activities, continuation) = AsyncStream.makeStream(of: InferenceActivity.self)
        Task { [weak self] in
            await self?.inference.setObserver { continuation.yield($0) }
            for await activity in activities { self?.apply(activity) }
        }
        downloader.onChange = { [weak self] in self?.downloads = $0 }
        downloader.tokenProvider = { [huggingFaceTokenStore] in huggingFaceTokenStore.load() }
        downloader.importer = { [weak self] url, projectorTarget in
            guard let self else { throw CancellationError() }
            return try await self.importDownloadedModel(at: url, projectorTarget: projectorTarget)
        }
    }

    var endpoint: String { "http://127.0.0.1:\(port)" }

    func applicationBecameActive() async {
        guard !appIsActive else { return }
        appIsActive = true
        if !hasCheckedPreviousSession, UserDefaults.standard.bool(forKey: Self.foregroundSessionKey) {
            await logs.write(.error, event: "previous_foreground_session_interrupted", details: "The previous foreground session ended without a background marker.")
        }
        hasCheckedPreviousSession = true
        debugSessionID = UUID().uuidString
        UserDefaults.standard.set(true, forKey: Self.foregroundSessionKey)
        await logs.write(.info, event: "app_foregrounded", requestID: debugSessionID)
    }

    func applicationBecameInactive() async {
        appIsActive = false
        await logs.write(.info, event: "app_inactive", requestID: debugSessionID)
    }

    func applicationEnteredBackground() async {
        appIsActive = false
        await logs.write(.info, event: "app_backgrounded", requestID: debugSessionID)
        UserDefaults.standard.set(false, forKey: Self.foregroundSessionKey)
        await stopServer()
    }

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
                logs: logs,
                modelLoader: { [weak self] id in
                    await self?.loadModelOnDemand(id) ?? false
                },
                modelControl: ModelControl(
                    installedModels: { [weak self] in await self?.modelManager.list() ?? [] },
                    downloads: { [weak self] in await self?.downloads ?? [] },
                    startDownload: { [weak self] repository, path, revision in
                        guard let self else { throw CancellationError() }
                        return try await self.startDownload(repository: repository, path: path, revision: revision)
                    }
                )
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
            lastError = "ポートは 1024〜65535 の範囲で指定してください。"
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
        if let observedThermalState, observedThermalState != metricsSnapshot?.thermalState {
            await logs.write(.warning, event: "thermal_state_changed", details: "\(observedThermalState)->\(metricsSnapshot?.thermalState ?? "unknown")")
        }
        observedThermalState = metricsSnapshot?.thermalState
        logPersistenceStatus = await logs.persistenceStatus()
        let active = await inference.activeModel()
        let capabilities = await inference.capabilities()
        supportsVision = active.loaded && capabilities.image
        logEntries = await logs.list()
        if apiKey.isEmpty { apiKey = (try? keyStore.loadOrCreate()) ?? "" }
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
            lastError = "ベンチマーク用の画像を作成できませんでした。"
            return
        }
        await runBenchmark(text: "Describe the colored shapes in this image.", image: ImageInput(data: data, mimeType: "image/png"))
    }

    func applyInferenceDefaults(maxTokens: Int, temperature: Double, contextTokens: Int, multiTokenPredictionEnabled: Bool) async {
        guard !modelLoading, !benchmarkRunning else {
            lastError = "モデルの処理が終わってから推論設定を適用してください。"
            return
        }
        modelLoading = true
        defer { modelLoading = false }
        guard !(await inference.hasActiveGeneration()) else {
            lastError = "実行中の推論が終わってから推論設定を適用してください。"
            return
        }
        guard (1...8192).contains(maxTokens), temperature.isFinite, (0...2).contains(temperature),
              [1024, 2048, 4096, 8192].contains(contextTokens), maxTokens <= contextTokens else {
            lastError = "出力トークン数はコンテキスト上限以下、temperature は 0〜2 で指定してください。"
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
                lastError = "ロード中のモデルが登録情報に見つからないため、推論設定の変更時にアンロードしました。"
                if shouldRestart { await startServer() }
                await refresh()
                return
            }
            do {
                try await inference.unloadModel()
                guard try await modelManager.verifyModel(id: id) else {
                    throw InferenceError.backendUnavailable("モデルファイルが見つからないか、SHA-256 が登録時と一致しません。")
                }
                try await inference.loadImportedModel(model, contextTokens: contextTokens, multiTokenPredictionEnabled: multiTokenPredictionEnabled)
                lastError = nil
            } catch {
                lastError = "コンテキスト上限の変更後、モデルの再ロードに失敗しました: \(error.localizedDescription)"
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
            lastError = "ベンチマークの前にモデルをロードしてください。"
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
            lastError = "ベンチマークに失敗しました: \(error.localizedDescription)"
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

    private static func diagnosticsLogURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("iPhoneLocalAI", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("logs.json")
    }
}

// MARK: - Model management

@MainActor
extension AppState {
    func importModels(from urls: [URL]) async {
        do {
            for url in urls { _ = try await modelManager.importModel(from: url) }
            await logs.write(.info, event: "models_imported", details: "count=\(urls.count)")
            lastError = nil
            await refresh()
        } catch {
            lastError = "モデルの取り込みに失敗しました: \(error.localizedDescription)"
        }
    }

    /// Imports model files placed in the app's Documents folder (USB file transfer or Files app).
    func importModelsFromDocuments() async {
        guard !modelImporting else { return }
        modelImporting = true
        defer { modelImporting = false }
        do {
            let imported = try await modelManager.importInbox()
            if !imported.isEmpty {
                await logs.write(.info, event: "models_imported_from_documents", details: "count=\(imported.count)")
                lastError = nil
            }
        } catch {
            lastError = "Documents フォルダからの取り込みに失敗しました: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Reloads the model that was loaded last time, so the API is usable again after a
    /// restart without touching the phone. Skipped once if the previous auto-load never
    /// finished (for example the app was killed for memory while loading).
    func autoLoadLastModel() async {
        guard !hasAttemptedAutoLoad else { return }
        hasAttemptedAutoLoad = true
        guard let id = UserDefaults.standard.string(forKey: Self.lastLoadedModelKey) else { return }
        if UserDefaults.standard.bool(forKey: Self.autoLoadInProgressKey) {
            UserDefaults.standard.set(false, forKey: Self.autoLoadInProgressKey)
            await logs.write(.warning, event: "model_auto_load_skipped", details: "The previous automatic load did not finish. model=\(id)")
            return
        }
        guard await modelManager.model(id: id) != nil else {
            UserDefaults.standard.removeObject(forKey: Self.lastLoadedModelKey)
            return
        }
        UserDefaults.standard.set(true, forKey: Self.autoLoadInProgressKey)
        await logs.write(.info, event: "model_auto_load_started", details: "model=\(id)")
        await loadModel(id)
        UserDefaults.standard.set(false, forKey: Self.autoLoadInProgressKey)
    }

    /// Called by the HTTP server when a chat request names an installed model that is not active.
    func loadModelOnDemand(_ id: String) async -> Bool {
        guard await modelManager.model(id: id) != nil else { return false }
        // A load already in progress (for example the automatic load at launch) makes
        // loadModel return immediately, so wait for it before deciding. Give up after 5 minutes.
        for _ in 0..<1500 where modelLoading {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if await inference.activeModel().id != id {
            await loadModel(id)
        }
        return await inference.activeModel().id == id
    }

    func loadModel(_ id: String) async {
        guard !modelLoading, !benchmarkRunning else { return }
        modelLoading = true
        defer { modelLoading = false }
        guard !(await inference.hasActiveGeneration()) else {
            lastError = "実行中の推論が終わってからモデルをロードしてください。"
            return
        }
        guard let model = await modelManager.model(id: id) else {
            lastError = "選択したモデルはインストールされていません。"
            return
        }
        var stage = "verify"
        await logs.write(.info, event: "model_verifying", details: "model=\(id)")
        do {
            guard try await modelManager.verifyModel(id: id) else {
                throw InferenceError.backendUnavailable("モデルファイルが見つからないか、SHA-256 が登録時と一致しません。")
            }
            stage = "load"
            try await inference.loadImportedModel(model, contextTokens: contextTokens, multiTokenPredictionEnabled: multiTokenPredictionEnabled)
            UserDefaults.standard.set(id, forKey: Self.lastLoadedModelKey)
            lastError = nil
        } catch {
            let nsError = error as NSError
            let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)
                .map { " underlying=\($0.domain)#\($0.code)" } ?? ""
            await logs.write(
                .error,
                event: "model_load_failed",
                details: "model=\(id) stage=\(stage) error=\(nsError.domain)#\(nsError.code)\(underlying)"
            )
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func unloadModel() async {
        guard !modelLoading, !benchmarkRunning else { return }
        modelLoading = true
        defer { modelLoading = false }
        guard !(await inference.hasActiveGeneration()) else {
            lastError = "実行中の推論が終わってからモデルをアンロードしてください。"
            return
        }
        do {
            try await inference.unloadModel()
            UserDefaults.standard.removeObject(forKey: Self.lastLoadedModelKey)
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
            lastError = "実行中の推論が終わってからモデルを削除してください。"
            return
        }
        do {
            let active = await inference.activeModel()
            if active.id == id {
                try await inference.unloadModel()
            }
            try await modelManager.removeModel(id: id)
            if UserDefaults.standard.string(forKey: Self.lastLoadedModelKey) == id {
                UserDefaults.standard.removeObject(forKey: Self.lastLoadedModelKey)
            }
            await logs.write(.info, event: "model_removed", details: "model=\(id)")
            await refresh()
        } catch {
            lastError = "モデルを削除できませんでした: \(error.localizedDescription)"
        }
    }
}

// MARK: - Live request

@MainActor
extension AppState {
    private func apply(_ activity: InferenceActivity) {
        switch activity {
        case let .started(request):
            liveRequest = LiveRequest(request)
        case let .text(requestID, text):
            guard liveRequest?.id == requestID else { return }
            liveRequest?.append(text)
        case let .finished(requestID, failed):
            guard liveRequest?.id == requestID else { return }
            liveRequest?.finish(failed: failed)
        }
    }
}

// MARK: - Hugging Face downloads

@MainActor
extension AppState {
    var huggingFaceClient: HuggingFaceClient { HuggingFaceClient(token: huggingFaceTokenStore.load()) }

    /// Starts a download chosen in the model browser. With `projector`, the image projector is
    /// downloaded after the model and attached to it.
    func startDownload(repository: String, file: HuggingFaceFile, projector: HuggingFaceFile? = nil) {
        do {
            let model = try downloader.enqueue(repository: repository, path: file.path, sizeBytes: file.sizeBytes)
            var details = "repository=\(repository) file=\(file.path)"
            if let projector {
                try downloader.enqueue(
                    repository: repository, path: projector.path, sizeBytes: projector.sizeBytes,
                    modelDownloadID: model.id
                )
                details += " projector=\(projector.path)"
            }
            lastError = nil
            Task { [details] in await logs.write(.info, event: "model_download_started", details: details) }
        } catch {
            lastError = "ダウンロードを開始できませんでした: \(error.localizedDescription)"
        }
    }

    /// Downloads an image projector for a model that is already installed.
    func startProjectorDownload(repository: String, projector: HuggingFaceFile, modelID: String) {
        do {
            try downloader.enqueue(
                repository: repository, path: projector.path, sizeBytes: projector.sizeBytes,
                projectorTargetID: modelID
            )
            lastError = nil
            let details = "repository=\(repository) projector=\(projector.path) model=\(modelID)"
            Task { await logs.write(.info, event: "model_download_started", details: details) }
        } catch {
            lastError = "ダウンロードを開始できませんでした: \(error.localizedDescription)"
        }
    }

    /// Starts a download requested through the API, after checking that the file exists.
    func startDownload(repository: String, path: String, revision: String) async throws -> ModelDownload {
        let files = try await huggingFaceClient.modelFiles(repository: repository, revision: revision)
        guard let file = files.first(where: { $0.path == path }) else { throw HuggingFaceError.notFound }
        let download = try downloader.enqueue(
            repository: repository, revision: revision, path: file.path, sizeBytes: file.sizeBytes
        )
        await logs.write(.info, event: "model_download_started", details: "repository=\(repository) file=\(path)")
        return download
    }

    /// Cancels an active download or clears a finished one from the list.
    func removeDownload(_ id: UUID) { downloader.remove(id) }

    func retryDownload(_ id: UUID) { downloader.retry(id) }

    /// Saves the Hugging Face access token in Keychain; an empty token removes it.
    func setHuggingFaceToken(_ token: String) {
        do {
            try huggingFaceTokenStore.save(token)
            hasHuggingFaceToken = huggingFaceTokenStore.load() != nil
            lastError = nil
        } catch {
            lastError = "Hugging Face のトークンを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func importDownloadedModel(at url: URL, projectorTarget: String?) async throws -> String {
        let model = try await modelManager.importModel(from: url, moveSource: true, projectorTarget: projectorTarget)
        await logs.write(.info, event: "model_downloaded", details: "model=\(model.id)")
        await refresh()
        return model.id
    }
}
