import Foundation
import XCTest
@testable import iPhoneLocalAI

final class HTTPServerTests: XCTestCase {
    func testHealthAuthModelsAndNonStreamingChat() async throws {
        let (server, baseURL) = try await startTestServer(port: 38251)
        do {
            let (healthData, healthResponse) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("health"))
            XCTAssertEqual((healthResponse as? HTTPURLResponse)?.statusCode, 200)
            let health = try XCTUnwrap(JSONSerialization.jsonObject(with: healthData) as? [String: Any])
            XCTAssertEqual(health["status"] as? String, "ok")

            var modelsRequest = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
            modelsRequest.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
            let (modelsData, modelsResponse) = try await URLSession.shared.data(for: modelsRequest)
            XCTAssertEqual((modelsResponse as? HTTPURLResponse)?.statusCode, 200)
            let models = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsData) as? [String: Any])
            let modelList = try XCTUnwrap(models["data"] as? [[String: Any]])
            XCTAssertEqual(modelList.first?["id"] as? String, "mock-echo")

            var capabilitiesRequest = URLRequest(url: baseURL.appendingPathComponent("capabilities"))
            capabilitiesRequest.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
            let (capabilitiesData, capabilitiesResponse) = try await URLSession.shared.data(for: capabilitiesRequest)
            XCTAssertEqual((capabilitiesResponse as? HTTPURLResponse)?.statusCode, 200)
            let capabilities = try XCTUnwrap(JSONSerialization.jsonObject(with: capabilitiesData) as? [String: Any])
            XCTAssertEqual(capabilities["server"] as? String, "iphone-local-ai")

            var metricsRequest = URLRequest(url: baseURL.appendingPathComponent("metrics"))
            metricsRequest.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
            let (metricsData, metricsResponse) = try await URLSession.shared.data(for: metricsRequest)
            XCTAssertEqual((metricsResponse as? HTTPURLResponse)?.statusCode, 200)
            let metrics = try XCTUnwrap(JSONSerialization.jsonObject(with: metricsData) as? [String: Any])
            XCTAssertEqual(metrics["model_loaded"] as? Bool, true)
            let memory = try XCTUnwrap(metrics["memory"] as? [String: Any])
            XCTAssertNotNil(memory["physical_footprint_mb"] as? Double)

            var logsRequest = URLRequest(url: baseURL.appendingPathComponent("logs"))
            logsRequest.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
            let (logsData, logsResponse) = try await URLSession.shared.data(for: logsRequest)
            XCTAssertEqual((logsResponse as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertNotNil(JSONSerialization.jsonObject(with: logsData) as? [[String: Any]])

            let (_, unauthenticatedMetrics) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("metrics"))
            XCTAssertEqual((unauthenticatedMetrics as? HTTPURLResponse)?.statusCode, 401)

            var chatRequest = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
            chatRequest.httpMethod = "POST"
            chatRequest.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
            chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            chatRequest.httpBody = Data(#"{"model":"mock-echo","messages":[{"role":"user","content":"hello"}]}"#.utf8)
            let (chatData, chatResponse) = try await URLSession.shared.data(for: chatRequest)
            XCTAssertEqual((chatResponse as? HTTPURLResponse)?.statusCode, 200)
            let completion = try XCTUnwrap(JSONSerialization.jsonObject(with: chatData) as? [String: Any])
            let choices = try XCTUnwrap(completion["choices"] as? [[String: Any]])
            let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
            XCTAssertTrue((message["content"] as? String)?.contains("Mock response: hello") == true)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    func testStreamingChatReturnsOpenAIEventsAndDoneMarker() async throws {
        let (server, baseURL) = try await startTestServer(port: 38252)
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
            request.httpMethod = "POST"
            request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(#"{"model":"mock-echo","messages":[{"role":"user","content":"stream me"}],"stream":true}"#.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let body = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertTrue(body.contains("chat.completion.chunk"))
            XCTAssertTrue(body.contains("data: [DONE]"))
            let payloads = body.components(separatedBy: "data: ").dropFirst()
            var streamedText = ""
            for payload in payloads {
                let jsonLine = String(payload.prefix(while: { $0 != "\n" })).trimmingCharacters(in: .whitespacesAndNewlines)
                guard jsonLine != "[DONE]", let event = try JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as? [String: Any],
                      let choices = event["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let text = delta["content"] as? String else { continue }
                streamedText += text
            }
            XCTAssertEqual(streamedText, "Mock response: stream me")
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func startTestServer(port: UInt16) async throws -> (HTTPServer, URL) {
        let metrics = MetricsService()
        let logs = LogService()
        let inference = InferenceService(metrics: metrics, logs: logs)
        let server = HTTPServer(port: port, apiKey: "test-key", allowLAN: false, inference: inference, metrics: metrics, logs: logs)
        try await server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }
}
