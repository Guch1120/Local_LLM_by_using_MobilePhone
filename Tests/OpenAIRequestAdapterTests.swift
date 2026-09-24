import XCTest
import UIKit
@testable import iPhoneLocalAI

final class OpenAIRequestAdapterTests: XCTestCase {
    func testAdaptsTextCompletionRequest() throws {
        let json = #"{"model":"mock-echo","messages":[{"role":"user","content":"Hello from the PC"}],"stream":true}"#
        let adapted = try OpenAIRequestAdapter.adapt(Data(json.utf8))

        XCTAssertEqual(adapted.inferenceRequest.model, "mock-echo")
        XCTAssertTrue(adapted.stream)
        XCTAssertEqual(adapted.inferenceRequest.messages.count, 1)
        XCTAssertEqual(adapted.inferenceRequest.messages[0].role, .user)
        guard case let .text(text) = adapted.inferenceRequest.messages[0].parts[0] else {
            return XCTFail("Expected text message content")
        }
        XCTAssertEqual(text, "Hello from the PC")
    }

    func testAppliesSavedGenerationDefaultsAndContextLimit() throws {
        let json = #"{"model":"mock-echo","messages":[{"role":"user","content":"hello"}]}"#
        let defaults = InferenceDefaults(maxTokens: 120, temperature: 0.4, contextTokens: 512)
        let adapted = try OpenAIRequestAdapter.adapt(Data(json.utf8), defaults: defaults)

        XCTAssertEqual(adapted.inferenceRequest.maxTokens, 120)
        XCTAssertEqual(adapted.inferenceRequest.temperature, 0.4)

        let tooManyTokens = #"{"model":"mock-echo","max_tokens":513,"messages":[{"role":"user","content":"hello"}]}"#
        XCTAssertThrowsError(try OpenAIRequestAdapter.adapt(Data(tooManyTokens.utf8), defaults: defaults))
    }

    func testDecodesPNGDataURLAlongsideText() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 20))
        let png = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
        }.pngData()!
        let dataURL = "data:image/png;base64,\(png.base64EncodedString())"
        let object: [String: Any] = [
            "model": "gemma-test",
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "Describe this"],
                ["type": "image_url", "image_url": ["url": dataURL]]
            ]]]
        ]
        let json = try JSONSerialization.data(withJSONObject: object)
        let adapted = try OpenAIRequestAdapter.adapt(json)
        let parts = adapted.inferenceRequest.messages[0].parts

        XCTAssertEqual(parts.count, 2)
        guard case let .image(image) = parts[1] else { return XCTFail("Expected image input") }
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertTrue(image.data.starts(with: [0xFF, 0xD8, 0xFF]))
    }

    func testRejectsRemoteImageURL() throws {
        let json = #"{"model":"mock-echo","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.test/photo.png"}}]}]}"#
        XCTAssertThrowsError(try OpenAIRequestAdapter.adapt(Data(json.utf8)))
    }

    func testRejectsImageBytesWithIncorrectSignature() throws {
        let encoded = Data([0, 1, 2]).base64EncodedString()
        let object: [String: Any] = [
            "model": "mock-echo",
            "messages": [["role": "user", "content": [[
                "type": "image_url",
                "image_url": ["url": "data:image/png;base64,\(encoded)"]
            ]]]]
        ]
        XCTAssertThrowsError(try OpenAIRequestAdapter.adapt(JSONSerialization.data(withJSONObject: object)))
    }
}
