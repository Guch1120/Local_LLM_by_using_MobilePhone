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

    func testStreamOptionsRequestUsageChunk() throws {
        let plain = #"{"model":"mock-echo","stream":true,"messages":[{"role":"user","content":"hi"}]}"#
        XCTAssertFalse(try OpenAIRequestAdapter.adapt(Data(plain.utf8)).includeUsage)

        let withUsage = #"{"model":"mock-echo","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hi"}]}"#
        XCTAssertTrue(try OpenAIRequestAdapter.adapt(Data(withUsage.utf8)).includeUsage)
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

    func testDecodesInputAudioAndChecksItsBytes() throws {
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0, 0, 0, 0x57, 0x41, 0x56, 0x45]) + Data(count: 36)
        let body = """
        {"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"What is said?"},\
        {"type":"input_audio","input_audio":{"data":"\(wav.base64EncodedString())","format":"wav"}}]}]}
        """
        let request = try OpenAIRequestAdapter.adapt(Data(body.utf8)).inferenceRequest
        guard case let .audio(data, mimeType) = request.messages[0].parts[1] else { return XCTFail("Expected an audio part") }
        XCTAssertEqual(data, wav)
        XCTAssertEqual(mimeType, "audio/wav")

        XCTAssertEqual(OpenAIRequestAdapter.audioType(of: Data("fLaC....".utf8)), "audio/flac")
        XCTAssertEqual(OpenAIRequestAdapter.audioType(of: Data([0x49, 0x44, 0x33, 4, 0])), "audio/mpeg")
        XCTAssertNil(OpenAIRequestAdapter.audioType(of: Data("not audio".utf8)))
        let notAudio = Data("hello".utf8).base64EncodedString()
        XCTAssertThrowsError(try OpenAIRequestAdapter.decodeAudio(base64: notAudio, format: "wav"))
        XCTAssertThrowsError(try OpenAIRequestAdapter.decodeAudio(base64: wav.base64EncodedString(), format: "mp3"))
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
