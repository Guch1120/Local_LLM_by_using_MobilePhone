import Foundation

/// A LoRA adapter (GGUF) installed for a llama.cpp model. llama.cpp adds it to the model's weights
/// when the model loads, so one model can serve several tasks with a small file each.
struct ModelAdapter: Codable, Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var path: String
    var sizeBytes: Int64
    var importedAt: Date

    var fileURL: URL { URL(fileURLWithPath: path) }

    /// The app container path changes across reinstalls, so resolve the file by name.
    func relocated(to directory: URL) -> ModelAdapter {
        var copy = self
        copy.path = directory.appendingPathComponent(fileURL.lastPathComponent).path
        return copy
    }
}

/// The few metadata values of a GGUF file that tell what the file is.
///
/// Only the start of the file is read. llama.cpp writes the `general.*` and `adapter.*` keys first, ahead of the
/// tokenizer arrays that make up most of a model's metadata, so a multi-gigabyte model is never scanned.
struct GGUFMetadata: Sendable, Equatable {
    private(set) var strings: [String: String] = [:]

    /// Adapters carry `general.type = adapter` (and `adapter.type = lora`).
    var isLoraAdapter: Bool { strings["general.type"] == "adapter" || strings["adapter.type"] == "lora" }
    /// For example `gemma4`; an adapter fits models of the same architecture.
    var architecture: String? { strings["general.architecture"] }

    static func read(from url: URL, maxBytes: Int = 256 * 1024) -> GGUFMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return parse(data)
    }

    /// Returns nil when the data is not a GGUF file (version 2 or 3). A truncated or unexpected
    /// value ends the scan; what was read until then is returned.
    static func parse(_ data: Data) -> GGUFMetadata? {
        var reader = ByteReader(data: data)
        guard reader.take(4) == Data("GGUF".utf8), let version = reader.uint32(), (2...3).contains(version),
              reader.take(8) != nil, let count = reader.lengthValue() else { return nil }
        var metadata = GGUFMetadata()
        for _ in 0..<min(count, 256) {
            guard let key = reader.string(), let type = reader.uint32() else { break }
            guard key.hasPrefix("general.") || key.hasPrefix("adapter.") else { break }
            if type == ValueType.string {
                guard let value = reader.string() else { break }
                metadata.strings[key] = value
            } else if !reader.skipValue(type: type) {
                break
            }
        }
        return metadata
    }

    private enum ValueType {
        static let string: UInt32 = 8
        static let array: UInt32 = 9
        /// Byte size of the fixed-size value types: u8 i8 u16 i16 u32 i32 f32 bool, then u64 i64 f64 at 10-12.
        static let fixedSizes: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
    }

    private struct ByteReader {
        let data: Data
        var offset = 0

        mutating func take(_ count: Int) -> Data? {
            guard count >= 0, count <= data.count - offset else { return nil }
            let start = data.startIndex + offset
            offset += count
            return data.subdata(in: start..<(start + count))
        }

        mutating func uint32() -> UInt32? { littleEndian(4).map { UInt32(truncatingIfNeeded: $0) } }
        /// A u64 that is used as a size or a count.
        mutating func lengthValue() -> Int? { littleEndian(8).flatMap { Int(exactly: $0) } }

        private mutating func littleEndian(_ count: Int) -> UInt64? {
            guard let bytes = take(count) else { return nil }
            var value: UInt64 = 0
            for (position, byte) in bytes.enumerated() {
                value |= UInt64(byte) << UInt64(8 * position)
            }
            return value
        }

        mutating func string() -> String? {
            guard let length = lengthValue(), let bytes = take(length) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }

        /// Steps over a value whose content is not needed; false when the data ends or the type is unknown.
        mutating func skipValue(type: UInt32) -> Bool {
            if let size = ValueType.fixedSizes[type] { return take(size) != nil }
            if type == ValueType.string { return string() != nil }
            guard type == ValueType.array, let elementType = uint32(), let count = lengthValue() else { return false }
            if let size = ValueType.fixedSizes[elementType] {
                let (bytes, overflow) = count.multipliedReportingOverflow(by: size)
                return !overflow && take(bytes) != nil
            }
            for _ in 0..<count {
                if !skipValue(type: elementType) { return false }
            }
            return true
        }
    }
}
