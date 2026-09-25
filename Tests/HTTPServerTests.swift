import Foundation
import XCTest
@testable import iPhoneLocalAI

final class HTTPServerTests: XCTestCase {
    func testHealthAuthModelsAndNonStreamingChat() async throws {
        let (server, logs) = makeTestServer()
        await logs.write(.info, event: "test_log_entry")

        let health = await dispatch(server, method: "GET", path: "/health", authorization: nil)
        XCTAssertEqual(health.status, 200)
        let healthBody = try XCTUnwrap(health.jsonBody as? [String: Any])
        XCTAssertEqual(healthBody["status"] as? String, "ok")

        let models = await dispatch(server, method: "GET", path: "/v1/models")
        XCTAssertEqual(models.status, 200)
        let modelsBody = try XCTUnwrap(models.jsonBody as? [String: Any])
        let modelList = try XCTUnwrap(modelsBody["data"] as? [[String: Any]])
        XCTAssertEqual(modelList.first?["id"] as? String, "mock-echo")

        let capabilities = await dispatch(server, method: "GET", path: "/capabilities")
        XCTAssertEqual(capabilities.status, 200)
        let capabilitiesBody = try XCTUnwrap(capabilities.jsonBody as? [String: Any])
        XCTAssertEqual(capabilitiesBody["server"] as? String, "iphone-local-ai")

        let metrics = await dispatch(server, method: "GET", path: "/metrics")
        XCTAssertEqual(metrics.status, 200)
        let metricsBody = try XCTUnwrap(metrics.jsonBody as? [String: Any])
        XCTAssertEqual(metricsBody["model_loaded"] as? Bool, true)
        let memory = try XCTUnwrap(metricsBody["memory"] as? [String: Any])
        XCTAssertNotNil(memory["physical_footprint_mb"] as? Double)

        let logsResponse = await dispatch(server, method: "GET", path: "/logs")
        XCTAssertEqual(logsResponse.status, 200)
        let logEntries = try XCTUnwrap(logsResponse.jsonBody as? [[String: Any]])
        XCTAssertFalse(logEntries.isEmpty)

        let unauthenticatedMetrics = await dispatch(server, method: "GET", path: "/metrics", authorization: nil)
        XCTAssertEqual(unauthenticatedMetrics.status, 401)

        let chatBody = Data(#"{"model":"mock-echo","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        let chat = await dispatch(server, method: "POST", path: "/v1/chat/completions", body: chatBody)
        XCTAssertEqual(chat.status, 200)
        let completion = try XCTUnwrap(chat.jsonBody as? [String: Any])
        let choices = try XCTUnwrap(completion["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertTrue((message["content"] as? String)?.contains("Mock response: hello") == true)
    }

    func testStreamingChatReturnsOpenAIEventsAndDoneMarker() async throws {
        let (server, _) = makeTestServer()
        let body = Data(#"{"model":"mock-echo","messages":[{"role":"user","content":"stream me"}],"stream":true}"#.utf8)
        let response = await dispatch(server, method: "POST", path: "/v1/chat/completions", body: body)

        XCTAssertTrue(response.eventStreamStarted)
        XCTAssertTrue(response.streamFinished)
        let firstEvent = try XCTUnwrap(response.events.first as? [String: Any])
        XCTAssertEqual(firstEvent["object"] as? String, "chat.completion.chunk")

        var streamedText = ""
        for event in response.events.compactMap({ $0 as? [String: Any] }) {
            guard let choices = event["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let text = delta["content"] as? String else { continue }
            streamedText += text
        }
        XCTAssertEqual(streamedText, "Mock response: stream me")
    }

    func testDiagnosticsRequiresBearerAndIncludesDebugBundle() async throws {
        let (server, logs) = makeTestServer()
        await logs.write(.warning, event: "diagnostics_test_event", details: "model=mock-echo")

        let unauthorized = await dispatch(server, method: "GET", path: "/diagnostics", authorization: nil)
        XCTAssertEqual(unauthorized.status, 401)

        let response = await dispatch(server, method: "GET", path: "/diagnostics")
        XCTAssertEqual(response.status, 200)
        let body = try XCTUnwrap(response.jsonBody as? [String: Any])
        let app = try XCTUnwrap(body["app"] as? [String: Any])
        XCTAssertNotNil(app["version"] as? String)
        XCTAssertNotNil(app["git_commit_sha"] as? String)
        let serverState = try XCTUnwrap(body["server"] as? [String: Any])
        XCTAssertEqual(serverState["port"] as? Int, 38251)
        let storedLogs = try XCTUnwrap(body["logs"] as? [[String: Any]])
        XCTAssertTrue(storedLogs.contains { $0["event"] as? String == "diagnostics_test_event" })
    }

    private func makeTestServer() -> (HTTPServer, LogService) {
        let metrics = MetricsService()
        let logs = LogService()
        let inference = InferenceService(metrics: metrics, logs: logs)
        let server = HTTPServer(
            port: 38251,
            apiKey: "test-key",
            allowLAN: false,
            inference: inference,
            metrics: metrics,
            logs: logs
        )
        return (server, logs)
    }

    private func dispatch(
        _ server: HTTPServer,
        method: String,
        path: String,
        authorization: String? = "Bearer test-key",
        body: Data = Data()
    ) async -> TestHTTPResponseSink {
        var headers: [String: String] = [:]
        if let authorization { headers["authorization"] = authorization }
        let request = HTTPIncomingRequest(method: method, target: path, headers: headers, body: body)
        let response = TestHTTPResponseSink()
        await server.handle(request, on: response)
        return response
    }
}

private final class TestHTTPResponseSink: HTTPResponseSink {
    private(set) var status: Int?
    private(set) var jsonBody: Any?
    private(set) var eventStreamStarted = false
    private(set) var streamFinished = false
    private(set) var events: [Any] = []

    func sendJSON(_ object: Any, status: Int) async {
        jsonBody = object
        self.status = status
    }

    func beginEventStream() async throws {
        eventStreamStarted = true
    }

    func sendEvent(_ object: Any) async throws {
        events.append(object)
    }

    func sendDone() async throws {
        streamFinished = true
    }

    func sendStreamError(_ object: Any) async {
        jsonBody = object
    }
}
