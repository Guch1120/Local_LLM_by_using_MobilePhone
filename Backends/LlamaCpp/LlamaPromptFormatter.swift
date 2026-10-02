import Foundation
import llama

/// Builds a Gemma 4 prompt, following the model's chat template for text, image and audio turns.
/// Images and audio clips are replaced by the mtmd media marker, in message order.
enum GemmaPromptFormatter {
    static func format(_ messages: [InferenceMessage], mediaMarker: String) -> (prompt: String, media: [Data]) {
        var prompt = ""
        var media: [Data] = []
        var remaining = messages[...]
        if let first = remaining.first, first.role == .system {
            prompt += "<|turn>system\n" + text(of: first).trimmingCharacters(in: .whitespacesAndNewlines) + "<turn|>\n"
            remaining = remaining.dropFirst()
        }
        for message in remaining {
            let role: String
            switch message.role {
            case .assistant: role = "model"
            case .system: role = "system"
            case .user, .tool: role = "user"
            }
            prompt += "<|turn>\(role)\n"
            for part in message.parts {
                switch part {
                case let .text(value):
                    prompt += value.trimmingCharacters(in: .whitespacesAndNewlines)
                case let .image(image):
                    prompt += "\n\n\(mediaMarker)\n\n"
                    media.append(image.data)
                case let .audio(data, _):
                    prompt += "\n\n\(mediaMarker)\n\n"
                    media.append(data)
                case let .tool(call):
                    prompt += "[Tool \(call.name): \(call.argumentsJSON)]"
                }
            }
            prompt += "<turn|>\n"
        }
        prompt += "<|turn>model\n"
        return (prompt, media)
    }

    private static func text(of message: InferenceMessage) -> String {
        message.parts.compactMap { part -> String? in
            if case let .text(value) = part { return value }
            return nil
        }.joined(separator: "\n")
    }
}

/// Builds a prompt with llama.cpp's chat template support, for models other than Gemma 4.
/// llama.cpp recognizes the common templates (ChatML, Llama, Phi, Mistral, Gemma 3, ...) without
/// a Jinja parser; a template it does not recognize falls back to ChatML.
enum TemplatePromptFormatter {
    typealias Turn = (role: String, content: String)

    static func format(
        _ messages: [InferenceMessage], template: String?, mediaMarker: String
    ) -> (prompt: String, media: [Data]) {
        var media: [Data] = []
        let turns: [Turn] = messages.map { message in
            var content = ""
            for part in message.parts {
                switch part {
                case let .text(value):
                    content += value
                case let .image(image):
                    content += "\n\(mediaMarker)\n"
                    media.append(image.data)
                case let .audio(data, _):
                    content += "\n\(mediaMarker)\n"
                    media.append(data)
                case let .tool(call):
                    content += "[Tool \(call.name): \(call.argumentsJSON)]"
                }
            }
            return (roleName(message.role), content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let prompt = template.flatMap { apply($0, to: turns) }
            ?? apply("chatml", to: turns)
            ?? turns.map(\.content).joined(separator: "\n")
        return (prompt, media)
    }

    private static func roleName(_ role: MessageRole) -> String {
        switch role {
        case .system: return "system"
        case .assistant: return "assistant"
        case .user, .tool: return "user"
        }
    }

    /// Returns nil when llama.cpp does not recognize the template.
    private static func apply(_ template: String, to turns: [Turn]) -> String? {
        // llama_chat_message holds C strings; keep copies alive for the duration of the call.
        let roles = turns.map { strdup($0.role) }
        let contents = turns.map { strdup($0.content) }
        defer { (roles + contents).forEach { free($0) } }
        let chat = turns.indices.map { llama_chat_message(role: roles[$0], content: contents[$0]) }

        var buffer = [CChar](repeating: 0, count: turns.reduce(1024) { $0 + $1.content.utf8.count * 2 + 64 })
        var length = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        if length > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(length) + 1)
            length = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        }
        guard length >= 0, length <= Int32(buffer.count) else { return nil }
        return String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
}
