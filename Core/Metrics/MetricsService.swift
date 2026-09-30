import Darwin
import Foundation

struct LastInferenceMetrics: Codable, Sendable {
    let promptTokens: Int
    let generatedTokens: Int
    let ttftMilliseconds: Double
    let decodeTokensPerSecond: Double
    let totalLatencyMilliseconds: Double
}

struct MetricsSnapshot: Codable, Sendable {
    let modelLoaded: Bool
    let model: String?
    let backend: String
    let thermalState: String
    let physicalFootprintMB: Double
    let lastInference: LastInferenceMetrics?
    let modelLoadMilliseconds: Double?
    let requestsTotal: Int
    let requestsFailed: Int
    let activeRequests: Int
    let uptimeSeconds: Double
    let tokenCountsEstimated: Bool
}

actor MetricsService {
    private let startedAt = Date()
    private var modelLoaded = true
    private var model: String? = "mock-echo"
    private var backend = "mock"
    private var lastInference: LastInferenceMetrics?
    private var modelLoadMilliseconds: Double? = 0
    private var requestsTotal = 0
    private var requestsFailed = 0
    private var activeRequests = 0
    private var lastCountsEstimated = true

    func setModel(loaded: Bool, model: String?, backend: String, loadMilliseconds: Double?) {
        modelLoaded = loaded
        self.model = model
        self.backend = backend
        modelLoadMilliseconds = loadMilliseconds
    }

    func beginRequest() {
        requestsTotal += 1
        activeRequests += 1
    }

    func finishRequest(
        promptTokens: Int,
        generatedTokens: Int,
        ttftMilliseconds: Double,
        totalLatencyMilliseconds: Double,
        failed: Bool,
        countsEstimated: Bool = true
    ) {
        activeRequests = max(0, activeRequests - 1)
        lastCountsEstimated = countsEstimated
        if failed { requestsFailed += 1 }
        let decodeMilliseconds = max(0, totalLatencyMilliseconds - ttftMilliseconds)
        let speed = decodeMilliseconds > 0 ? Double(generatedTokens) / (decodeMilliseconds / 1000) : 0
        lastInference = LastInferenceMetrics(
            promptTokens: promptTokens,
            generatedTokens: generatedTokens,
            ttftMilliseconds: ttftMilliseconds,
            decodeTokensPerSecond: speed,
            totalLatencyMilliseconds: totalLatencyMilliseconds
        )
    }

    func snapshot() -> MetricsSnapshot {
        MetricsSnapshot(
            modelLoaded: modelLoaded,
            model: model,
            backend: backend,
            thermalState: Self.thermalState,
            physicalFootprintMB: Self.physicalFootprintMB,
            lastInference: lastInference,
            modelLoadMilliseconds: modelLoadMilliseconds,
            requestsTotal: requestsTotal,
            requestsFailed: requestsFailed,
            activeRequests: activeRequests,
            uptimeSeconds: Date().timeIntervalSince(startedAt),
            tokenCountsEstimated: lastCountsEstimated
        )
    }

    static var thermalState: String {
        return switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private static var physicalFootprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
