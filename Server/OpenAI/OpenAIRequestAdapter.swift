import Foundation
import ImageIO

enum RequestValidationError: Error, LocalizedError {
    case invalid(String)
    case unsupportedModality(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message), let .unsupportedModality(message): message
        }
    }
}

struct AdaptedChatRequest {
    let inferenceRequest: InferenceRequest
    let stream: Bool
    /// `stream_options.include_usage`: send a final streaming chunk that carries token usage.
    var includeUsage = false
}

enum OpenAIRequestAdapter {
    static let maximumImageBytes = 12 * 1024 * 1024

    static func adapt(_ data: Data, defaults: InferenceDefaults = .standard) throws -> AdaptedChatRequest {
        let input: OpenAIChatRequest
        do {
            input = try JSONDecoder().decode(OpenAIChatRequest.self, from: data)
        } catch {
            throw RequestValidationError.invalid("The chat completion request is not valid JSON or has an invalid shape.")
        }
        guard !input.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RequestValidationError.invalid("The 'model' field is required.")
        }
        guard !input.messages.isEmpty else {
            throw RequestValidationError.invalid("At least one message is required.")
        }
        let maxTokens = input.maxCompletionTokens ?? input.maxTokens ?? defaults.maxTokens
        guard (1...defaults.contextTokens).contains(maxTokens) else {
            throw RequestValidationError.invalid("max_tokens must be between 1 and the configured context limit (\(defaults.contextTokens)).")
        }
        let temperature = input.temperature ?? defaults.temperature
        guard temperature.isFinite, (0...2).contains(temperature) else {
            throw RequestValidationError.invalid("temperature must be between 0 and 2.")
        }

        let messages = try input.messages.map { message -> InferenceMessage in
            guard let role = MessageRole(rawValue: message.role) else {
                throw RequestValidationError.invalid("Unsupported message role '\(message.role)'.")
            }
            let parts: [MessagePart]
            switch message.content {
            case let .text(text):
                parts = [.text(text)]
            case let .parts(contentParts):
                parts = try contentParts.map { part in
                    switch part.type {
                    case "text":
                        guard let text = part.text else { throw RequestValidationError.invalid("A text content part is missing its text.") }
                        return .text(text)
                    case "image_url":
                        guard let url = part.imageURL?.url else { throw RequestValidationError.invalid("An image_url content part is missing its URL.") }
                        return .image(try decodeImageDataURL(url))
                    case "input_audio":
                        guard let audio = part.inputAudio else {
                            throw RequestValidationError.invalid("An input_audio content part is missing its data.")
                        }
                        return try decodeAudio(audio)
                    default:
                        throw RequestValidationError.unsupportedModality("Unsupported content type '\(part.type)'.")
                    }
                }
            }
            return InferenceMessage(role: role, parts: parts)
        }

        return AdaptedChatRequest(
            inferenceRequest: InferenceRequest(
                id: UUID().uuidString,
                model: input.model,
                messages: messages,
                maxTokens: maxTokens,
                temperature: temperature
            ),
            stream: input.stream ?? false,
            includeUsage: input.streamOptions?.includeUsage ?? false
        )
    }

    private static func decodeImageDataURL(_ value: String) throws -> ImageInput {
        let supported = [
            ("data:image/jpeg;base64,", "image/jpeg", [UInt8](arrayLiteral: 0xFF, 0xD8, 0xFF)),
            ("data:image/png;base64,", "image/png", [UInt8](arrayLiteral: 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))
        ]
        guard let match = supported.first(where: { value.hasPrefix($0.0) }) else {
            throw RequestValidationError.unsupportedModality("Only base64 JPEG and PNG image data URLs are supported.")
        }
        let encoded = String(value.dropFirst(match.0.count))
        guard encoded.utf8.count <= maximumImageBytes * 4 / 3 + 16,
              let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty,
              bytes.count <= maximumImageBytes else {
            throw RequestValidationError.invalid("The image data URL is invalid or exceeds the 12 MiB decoded image limit.")
        }
        guard bytes.starts(with: match.2) else {
            throw RequestValidationError.invalid("The image bytes do not match the declared JPEG or PNG type.")
        }
        return try normalizeImage(bytes)
    }

    /// OpenAI's `input_audio` part: base64 WAV or MP3 (FLAC is accepted too), checked by its bytes.
    static func decodeAudio(base64 encoded: String, format: String?) throws -> MessagePart {
        guard encoded.utf8.count <= maximumImageBytes * 4 / 3 + 16,
              let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= maximumImageBytes else {
            throw RequestValidationError.invalid("The audio data is invalid or exceeds the 12 MiB limit.")
        }
        guard let mimeType = audioType(of: bytes) else {
            throw RequestValidationError.unsupportedModality("Only WAV, MP3 and FLAC audio is supported.")
        }
        if let format, !mimeType.hasSuffix(format.lowercased()), !(format.lowercased() == "mp3" && mimeType == "audio/mpeg") {
            throw RequestValidationError.invalid("The audio bytes do not match the declared format '\(format)'.")
        }
        return .audio(bytes, mimeType: mimeType)
    }

    private static func decodeAudio(_ audio: OpenAIInputAudio) throws -> MessagePart {
        try decodeAudio(base64: audio.data, format: audio.format)
    }

    /// WAV ("RIFF....WAVE"), FLAC ("fLaC") or MP3 (ID3 tag or an MPEG frame sync).
    static func audioType(of bytes: Data) -> String? {
        let head = [UInt8](bytes.prefix(12))
        if head.count >= 12, head[0..<4] == [0x52, 0x49, 0x46, 0x46], head[8..<12] == [0x57, 0x41, 0x56, 0x45] {
            return "audio/wav"
        }
        if head.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return "audio/flac" }
        if head.starts(with: [0x49, 0x44, 0x33]) || (head.count >= 2 && head[0] == 0xFF && head[1] & 0xE0 == 0xE0) {
            return "audio/mpeg"
        }
        return nil
    }

    /// Orientation-corrected JPEG with at most 2048 pixels on the long edge.
    static func normalizeImage(_ data: Data) throws -> ImageInput {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw RequestValidationError.invalid("The image data could not be decoded.")
        }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw RequestValidationError.invalid("The image data could not be decoded.")
        }
        let jpegData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpegData, "public.jpeg" as CFString, 1, nil) else {
            throw RequestValidationError.invalid("The image could not be converted to a supported format.")
        }
        CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw RequestValidationError.invalid("The image could not be converted to a supported format.")
        }
        return ImageInput(data: jpegData as Data, mimeType: "image/jpeg")
    }
}

private struct OpenAIChatRequest: Decodable {
    let model: String
    let messages: [OpenAIMessage]
    let stream: Bool?
    let maxTokens: Int?
    let maxCompletionTokens: Int?
    let temperature: Double?
    let streamOptions: OpenAIStreamOptions?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case streamOptions = "stream_options"
    }
}

private struct OpenAIStreamOptions: Decodable {
    let includeUsage: Bool?

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct OpenAIMessage: Decodable {
    let role: String
    let content: OpenAIContent
}

private enum OpenAIContent: Decodable {
    case text(String)
    case parts([OpenAIContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([OpenAIContentPart].self))
        }
    }
}

private struct OpenAIContentPart: Decodable {
    let type: String
    let text: String?
    let imageURL: OpenAIImageURL?
    let inputAudio: OpenAIInputAudio?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
        case inputAudio = "input_audio"
    }
}

private struct OpenAIInputAudio: Decodable {
    let data: String
    let format: String?
}

private struct OpenAIImageURL: Decodable {
    let url: String
}
