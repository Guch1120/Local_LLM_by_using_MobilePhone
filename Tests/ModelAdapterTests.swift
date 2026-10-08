import Foundation
import XCTest
@testable import iPhoneLocalAI

/// LoRA adapters: recognizing the GGUF file, attaching it to a model, and choosing the active one.
final class ModelAdapterTests: XCTestCase {
    func testGGUFMetadataRecognizesLoraAdapter() throws {
        let data = GGUFBuilder.file([
            ("general.architecture", .string("gemma4")), ("general.type", .string("adapter")),
            ("adapter.type", .string("lora")), ("adapter.lora.alpha", .float(32))
        ])
        let metadata = try XCTUnwrap(GGUFMetadata.parse(data))
        XCTAssertTrue(metadata.isLoraAdapter)
        XCTAssertEqual(metadata.architecture, "gemma4")
    }

    func testGGUFMetadataStepsOverArraysAndStopsAtModelKeys() throws {
        let adapter = GGUFBuilder.file([
            ("general.architecture", .string("gemma4")), ("general.tags", .stringArray(["a", "bb"])),
            ("general.sizes", .uint32Array([1, 2, 3])), ("general.file_type", .uint32(1)), ("general.type", .string("adapter"))
        ])
        XCTAssertEqual(GGUFMetadata.parse(adapter)?.isLoraAdapter, true)

        // The reader stops at the first key outside general.* and adapter.*: a model's tokenizer arrays are never scanned.
        let model = GGUFBuilder.file([
            ("general.architecture", .string("gemma4")), ("gemma4.block_count", .uint32(35)), ("general.type", .string("adapter"))
        ])
        let metadata = try XCTUnwrap(GGUFMetadata.parse(model))
        XCTAssertFalse(metadata.isLoraAdapter)
        XCTAssertEqual(metadata.architecture, "gemma4")
    }

    func testGGUFMetadataRejectsOtherData() {
        XCTAssertNil(GGUFMetadata.parse(Data("not a gguf file".utf8)))
        XCTAssertNil(GGUFMetadata.parse(Data("GGUF".utf8)))
        var oldVersion = Data("GGUF".utf8)
        oldVersion.appendLittleEndian(UInt32(1))
        oldVersion.appendLittleEndian(UInt64(0))
        oldVersion.appendLittleEndian(UInt64(0))
        XCTAssertNil(GGUFMetadata.parse(oldVersion))
        // A file that ends in the middle of a value keeps what was read before it.
        let truncated = GGUFBuilder.file([("general.architecture", .string("gemma4")), ("general.name", .string("name"))]).dropLast(2)
        XCTAssertEqual(GGUFMetadata.parse(Data(truncated))?.architecture, "gemma4")
    }

    func testRegistryWrittenBeforeAdaptersStillDecodes() throws {
        let json = """
        [{"id":"m","name":"m","backend":"llama.cpp","path":"/x","sha256":"0","sizeBytes":1,"modalities":["text"],"importedAt":0}]
        """
        let models = try JSONDecoder().decode([InstalledModel].self, from: Data(json.utf8))
        XCTAssertNil(models.first?.adapters)
        XCTAssertNil(models.first?.activeAdapter)
    }

    func testAdapterAttachesToTheModelOfItsArchitectureAndIsChosenExplicitly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Models", isDirectory: true)
        let manager = ModelManager(directoryURL: directory)
        // "other" is imported last, so the newest model is not the one the adapter fits.
        for (name, architecture) in [("gemma", "gemma4"), ("other", "qwen3")] {
            let source = root.appendingPathComponent("\(name).gguf")
            try GGUFBuilder.file([("general.architecture", .string(architecture)), ("general.name", .string(name))]).write(to: source)
            _ = try await manager.importModel(from: source)
        }
        let adapterFile = root.appendingPathComponent("task-lora.gguf")
        try GGUFBuilder.file([("general.architecture", .string("gemma4")), ("general.type", .string("adapter"))]).write(to: adapterFile)

        let attached = try await manager.importModel(from: adapterFile)
        XCTAssertEqual(attached.id, "gemma")
        XCTAssertEqual(attached.adapters?.map(\.id), ["task-lora"])
        XCTAssertNil(attached.activeAdapterID, "an imported adapter stays inactive until it is chosen")
        let otherModel = await manager.model(id: "other")
        XCTAssertNil(otherModel?.adapters)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(attached.adapters?.first?.path)))

        try await manager.setActiveAdapter(modelID: "gemma", adapterID: "task-lora")
        let reopened = await ModelManager(directoryURL: directory).model(id: "gemma")
        XCTAssertEqual(reopened?.activeAdapter?.name, "task-lora")

        do {
            try await manager.setActiveAdapter(modelID: "gemma", adapterID: "missing")
            XCTFail("Expected an unknown adapter to be rejected")
        } catch let error as ModelImportError {
            XCTAssertEqual(error.localizedDescription, "The model this LoRA adapter belongs to is not installed.")
        }

        try await manager.removeAdapter(modelID: "gemma", adapterID: "task-lora")
        let afterRemoval = await manager.model(id: "gemma")
        XCTAssertEqual(afterRemoval?.adapters, [])
        XCTAssertNil(afterRemoval?.activeAdapterID)
    }

    func testAdapterFollowsTheRequestedModelAndIsRejectedWithoutOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(directoryURL: root.appendingPathComponent("Models", isDirectory: true))
        let adapterFile = root.appendingPathComponent("adapter.gguf")
        try GGUFBuilder.file([("general.architecture", .string("gemma4")), ("general.type", .string("adapter"))]).write(to: adapterFile)
        do {
            _ = try await manager.importModel(from: adapterFile)
            XCTFail("Expected an adapter without any model to be rejected")
        } catch let error as ModelImportError {
            XCTAssertEqual(error.localizedDescription, "Import the GGUF model before its LoRA adapter file.")
        }

        let source = root.appendingPathComponent("base.gguf")
        try GGUFBuilder.file([("general.architecture", .string("llama")), ("general.name", .string("base"))]).write(to: source)
        _ = try await manager.importModel(from: source)
        // No model has the adapter's architecture, so it goes to the newest llama.cpp model, or to the one named.
        let named = try await manager.importModel(from: adapterFile, projectorTarget: "base")
        XCTAssertEqual(named.adapters?.count, 1)

        let adapterPath = try XCTUnwrap(named.adapters?.first?.path)
        try await manager.removeModel(id: "base")
        XCTAssertFalse(FileManager.default.fileExists(atPath: adapterPath), "removing a model removes its adapters")
    }

    func testInboxImportsAdaptersAfterTheirModel() {
        let urls = ["z-lora.gguf", "mmproj-a.gguf", "a-model.gguf", "adapter-b.gguf"].map { URL(fileURLWithPath: "/inbox/\($0)") }
        let ordered = ModelManager.importOrder(urls).map(\.lastPathComponent)
        XCTAssertEqual(ordered.first, "a-model.gguf")
        XCTAssertEqual(Set(ordered.dropFirst()), ["z-lora.gguf", "mmproj-a.gguf", "adapter-b.gguf"])
    }
}

/// Writes the start of a GGUF file: header and key-value metadata, no tensors.
private enum GGUFBuilder {
    enum Value {
        case string(String), uint32(UInt32), float(Float), stringArray([String]), uint32Array([UInt32])
    }

    static func file(_ entries: [(String, Value)]) -> Data {
        var data = Data("GGUF".utf8)
        data.appendLittleEndian(UInt32(3))
        data.appendLittleEndian(UInt64(0))
        data.appendLittleEndian(UInt64(entries.count))
        for (key, value) in entries {
            data.appendString(key)
            switch value {
            case let .string(text):
                data.appendLittleEndian(UInt32(8))
                data.appendString(text)
            case let .uint32(number):
                data.appendLittleEndian(UInt32(4))
                data.appendLittleEndian(number)
            case let .float(number):
                data.appendLittleEndian(UInt32(6))
                data.appendLittleEndian(number.bitPattern)
            case let .stringArray(items):
                data.appendLittleEndian(UInt32(9))
                data.appendLittleEndian(UInt32(8))
                data.appendLittleEndian(UInt64(items.count))
                items.forEach { data.appendString($0) }
            case let .uint32Array(items):
                data.appendLittleEndian(UInt32(9))
                data.appendLittleEndian(UInt32(4))
                data.appendLittleEndian(UInt64(items.count))
                items.forEach { data.appendLittleEndian($0) }
            }
        }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendString(_ text: String) {
        appendLittleEndian(UInt64(text.utf8.count))
        append(Data(text.utf8))
    }
}
