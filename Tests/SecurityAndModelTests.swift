import CryptoKit
import Foundation
import XCTest
@testable import iPhoneLocalAI

final class SecurityAndModelTests: XCTestCase {
    func testBearerTokenComparison() {
        XCTAssertTrue(BearerTokenAuthenticator.matches("Bearer abc123", expectedToken: "abc123"))
        XCTAssertFalse(BearerTokenAuthenticator.matches("Bearer abc124", expectedToken: "abc123"))
        XCTAssertFalse(BearerTokenAuthenticator.matches("abc123", expectedToken: "abc123"))
        XCTAssertFalse(BearerTokenAuthenticator.matches("Bearer abc123 ", expectedToken: "abc123"))
    }

    func testDiagnosticLogsPersistAcrossServiceInstances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = root.appendingPathComponent("diagnostics/logs.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let first = LogService(capacity: 3, persistenceURL: archiveURL)
        await first.write(.error, event: "persisted_error", details: "safe diagnostic detail")
        let initialStatus = await first.persistenceStatus()
        XCTAssertTrue(initialStatus.enabled)
        XCTAssertTrue(initialStatus.healthy)

        let relaunched = LogService(capacity: 3, persistenceURL: archiveURL)
        let entries = await relaunched.list()
        XCTAssertEqual(entries.first?.event, "persisted_error")
        XCTAssertEqual(entries.first?.details, "safe diagnostic detail")
        let relaunchedStatus = await relaunched.persistenceStatus()
        XCTAssertTrue(relaunchedStatus.healthy)
    }

    func testModelImportCopiesFileAndVerifiesDigest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelDirectory = root.appendingPathComponent("Models", isDirectory: true)
        let source = root.appendingPathComponent("tiny-test.litertlm")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("local test model".utf8)
        try bytes.write(to: source)
        let manager = ModelManager(directoryURL: modelDirectory)

        let imported = try await manager.importModel(from: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.path))
        XCTAssertEqual(imported.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let initiallyValid = try await manager.verifyModel(id: imported.id)
        XCTAssertTrue(initiallyValid)

        try Data("modified".utf8).write(to: imported.fileURL)
        let stillValid = try await manager.verifyModel(id: imported.id)
        XCTAssertFalse(stillValid)
    }

    func testInboxImportMovesModelsAndSkipsOtherFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = inbox.appendingPathComponent("inbox-model.litertlm")
        try Data("inbox model".utf8).write(to: source)
        try Data("notes".utf8).write(to: inbox.appendingPathComponent("notes.txt"))
        let manager = ModelManager(directoryURL: root.appendingPathComponent("Models", isDirectory: true), inboxURL: inbox)

        let imported = try await manager.importInbox()
        XCTAssertEqual(imported.map(\.id), ["inbox-model"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("notes.txt").path))
        let second = try await manager.importInbox()
        XCTAssertTrue(second.isEmpty)
    }

    func testInboxImportAttachesProjectorToGGUFModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // The projector sorts first by name, but must be imported after its model.
        try Data("projector".utf8).write(to: inbox.appendingPathComponent("mmproj-tiny-Q8_0.gguf"))
        try Data("weights".utf8).write(to: inbox.appendingPathComponent("tiny-Q4_0.gguf"))
        let manager = ModelManager(directoryURL: root.appendingPathComponent("Models", isDirectory: true), inboxURL: inbox)

        _ = try await manager.importInbox()
        let models = await manager.list()
        XCTAssertEqual(models.map(\.id), ["tiny-q4_0"])
        let model = try XCTUnwrap(models.first)
        XCTAssertEqual(model.backend, "llama.cpp")
        XCTAssertEqual(model.modalities, ["text", "image"])
        let projector = try XCTUnwrap(model.projectorPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projector))

        try await manager.removeModel(id: model.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projector))
    }

    func testProjectorAttachesToTheRequestedModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(directoryURL: root.appendingPathComponent("Models", isDirectory: true))
        for name in ["first", "second"] {
            let source = root.appendingPathComponent("\(name).gguf")
            try Data("weights \(name)".utf8).write(to: source)
            _ = try await manager.importModel(from: source)
        }
        let projector = root.appendingPathComponent("mmproj-first.gguf")
        try Data("projector".utf8).write(to: projector)

        let attached = try await manager.importModel(from: projector, projectorTarget: "first")
        XCTAssertEqual(attached.id, "first")
        XCTAssertEqual(attached.modalities, ["text", "image"])
        let second = await manager.model(id: "second")
        XCTAssertNil(second?.projectorPath)

        do {
            _ = try await manager.importModel(from: projector, projectorTarget: "missing")
            XCTFail("Expected an unknown projector target to be rejected")
        } catch let error as ModelImportError {
            XCTAssertEqual(error.localizedDescription, "The model this image projector belongs to is not installed.")
        }
    }

    func testProjectorWithoutGGUFModelIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("mmproj-orphan.gguf")
        try Data("projector".utf8).write(to: source)
        let manager = ModelManager(directoryURL: root.appendingPathComponent("Models", isDirectory: true))

        do {
            _ = try await manager.importModel(from: source)
            XCTFail("Expected a projector without a GGUF model to be rejected")
        } catch let error as ModelImportError {
            XCTAssertEqual(error.localizedDescription, ModelImportError.projectorWithoutModel.localizedDescription)
        }
    }

    func testRegistryResolvesModelsAfterContainerPathChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modelDirectory = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("weights".utf8).write(to: modelDirectory.appendingPathComponent("moved.litertlm"))
        let stale = InstalledModel(
            id: "moved",
            name: "moved",
            backend: "litert-lm",
            path: "/private/var/mobile/Containers/Data/Application/OLD-UUID/Library/Application Support/Models/moved.litertlm",
            sha256: "0",
            sizeBytes: 7,
            modalities: ["text", "image"],
            importedAt: Date()
        )
        try JSONEncoder().encode([stale]).write(to: modelDirectory.appendingPathComponent("models.json"))

        let manager = ModelManager(directoryURL: modelDirectory)
        let models = await manager.list()
        XCTAssertEqual(models.map(\.id), ["moved"])
        XCTAssertEqual(models.first?.modalities, ["text"])
        XCTAssertEqual(models.first?.path, modelDirectory.appendingPathComponent("moved.litertlm").path)
    }

    func testModelImportRejectsNonLiteRTFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("weights.bin")
        try Data("not a LiteRT-LM model".utf8).write(to: source)
        let manager = ModelManager(directoryURL: root.appendingPathComponent("Models", isDirectory: true))

        do {
            _ = try await manager.importModel(from: source)
            XCTFail("Expected a non-LiteRT model file to be rejected")
        } catch let error as ModelImportError {
            XCTAssertEqual(error.localizedDescription, "Only .litertlm or .gguf model files can be imported.")
        }
    }

    func testInferenceServiceReportsRunningRequestsInOrder() async throws {
        let service = InferenceService(metrics: MetricsService(), logs: LogService())
        let (activities, continuation) = AsyncStream.makeStream(of: InferenceActivity.self)
        await service.setObserver { continuation.yield($0) }
        let request = InferenceRequest(
            id: "live-1", model: "mock-echo",
            messages: [InferenceMessage(role: .user, parts: [.text("hello there")])],
            maxTokens: 16, temperature: 0
        )

        var reply = ""
        for try await chunk in try await service.generate(request) { reply += chunk.text }

        var events: [String] = []
        var reported = ""
        loop: for await activity in activities {
            switch activity {
            case let .started(started):
                events.append("started \(started.id)")
            case let .text(_, text):
                reported += text
            case let .finished(requestID, failed, truncated):
                events.append("finished \(requestID) failed=\(failed || truncated)")
                break loop
            }
        }
        XCTAssertEqual(events, ["started live-1", "finished live-1 failed=false"])
        XCTAssertEqual(reported, reply)
        XCTAssertEqual(reply, "Mock response: hello there")
    }

    func testTemplateFormatterAppliesChatMLAndKeepsImageOrder() {
        let image = ImageInput(data: Data([1, 2, 3]), mimeType: "image/png")
        let messages = [
            InferenceMessage(role: .system, parts: [.text("Be brief.")]),
            InferenceMessage(role: .user, parts: [.text("What is this?"), .image(image)])
        ]
        let result = TemplatePromptFormatter.format(messages, template: "chatml", mediaMarker: "<__media__>")
        XCTAssertEqual(
            result.prompt,
            "<|im_start|>system\nBe brief.<|im_end|>\n"
                + "<|im_start|>user\nWhat is this?\n<__media__><|im_end|>\n"
                + "<|im_start|>assistant\n"
        )
        XCTAssertEqual(result.images, [image.data])
    }

    func testTemplateFormatterFallsBackToChatMLForUnknownTemplate() {
        let messages = [InferenceMessage(role: .user, parts: [.text("Hello")])]
        let expected = "<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n"
        for template in ["{{ not a template llama.cpp knows }}", nil] {
            let result = TemplatePromptFormatter.format(messages, template: template, mediaMarker: "<__media__>")
            XCTAssertEqual(result.prompt, expected)
        }
    }
}
