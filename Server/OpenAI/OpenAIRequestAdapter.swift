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

    private static func normalizeImage(_ data: Data) throws -> ImageInput {
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

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }
}

private struct OpenAIImageURL: Decodable {
    let url: String
}
