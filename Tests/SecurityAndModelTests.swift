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
        XCTAssertEqual(result.media, [image.data])

        let clip = Data("RIFF....WAVEfmt ".utf8)
        let spoken = [InferenceMessage(role: .user, parts: [.text("What is said?"), .audio(clip, mimeType: "audio/wav")])]
        let gemma = GemmaPromptFormatter.format(spoken, mediaMarker: "<__media__>")
        XCTAssertEqual(gemma.prompt, "<|turn>user\nWhat is said?\n\n<__media__>\n\n<turn|>\n<|turn>model\n")
        XCTAssertEqual(gemma.media, [clip])
    }

    func testTemplateFormatterFallsBackToChatMLForUnknownTemplate() {
        let messages = [InferenceMessage(role: .user, parts: [.text("Hello")])]
        let expected = "<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n"
        for template in ["{{ not a template llama.cpp knows }}", nil] {
            let result = TemplatePromptFormatter.format(messages, template: template, mediaMarker: "<__media__>")
            XCTAssertEqual(result.prompt, expected)
        }
    }

    func testThermalPolicyPausesOnlyAtCriticalByDefault() {
        XCTAssertFalse(ThermalPolicy.shouldPause(.nominal, pauseOnSerious: false))
        XCTAssertFalse(ThermalPolicy.shouldPause(.fair, pauseOnSerious: false))
        XCTAssertFalse(ThermalPolicy.shouldPause(.serious, pauseOnSerious: false))
        XCTAssertTrue(ThermalPolicy.shouldPause(.critical, pauseOnSerious: false))

        XCTAssertFalse(ThermalPolicy.shouldPause(.fair, pauseOnSerious: true))
        XCTAssertTrue(ThermalPolicy.shouldPause(.serious, pauseOnSerious: true))
        XCTAssertTrue(ThermalPolicy.shouldPause(.critical, pauseOnSerious: true))
    }

    func testContextLengthErrorStatesBothNumbers() {
        let error = InferenceError.contextLengthExceeded(promptTokens: 10_783, contextTokens: 8_192)
        XCTAssertEqual(
            error.localizedDescription,
            "The prompt needs 10783 tokens, but the context holds 8192. Shorten it or raise the context length."
        )
    }

    // MARK: - Prompt cache (KV cache reuse)

    func testPromptCacheKeepsTheStartOfAContinuedConversation() {
        var cache = PromptCache()
        let turn1: [PromptSegment] = [.text([1, 2, 3, 4, 5])]
        cache.store(prompt: turn1, generated: [6, 7])

        // The next turn repeats the first prompt and the reply, then adds the new question.
        let turn2: [PromptSegment] = [.text([1, 2, 3, 4, 5, 6, 7, 8, 9])]
        let reuse = cache.reuse(for: turn2)
        XCTAssertEqual(reuse.keptPositions, 7)
        XCTAssertEqual(reuse.resumeSegment, 0)
        XCTAssertEqual(reuse.resumeTokenOffset, 7)
    }

    func testPromptCacheStopsAtTheFirstDifference() {
        var cache = PromptCache()
        cache.store(prompt: [.text([1, 2, 3, 4, 5])], generated: [])
        // The reply came back with different tokens: only the matching start stays.
        let reuse = cache.reuse(for: [.text([1, 2, 3, 9, 9, 9])])
        XCTAssertEqual(reuse.keptPositions, 3)
        XCTAssertEqual(reuse.resumeTokenOffset, 3)

        // A change in the very first token keeps nothing.
        XCTAssertEqual(cache.reuse(for: [.text([9, 2, 3])]).keptPositions, 0)
    }

    func testPromptCacheRecognisesTheSameImageByItsHash() {
        var cache = PromptCache()
        let image = PromptSegment.media(id: "abc", tokens: 134, positions: 134)
        cache.store(prompt: [.text([1, 2]), image, .text([3, 4])], generated: [5])

        // Same picture, longer text after it: the image is not encoded again.
        let same = cache.reuse(for: [.text([1, 2]), image, .text([3, 4, 5, 6])])
        XCTAssertEqual(same.keptPositions, 2 + 134 + 3)
        XCTAssertEqual(same.resumeSegment, 2)
        XCTAssertEqual(same.resumeTokenOffset, 3)

        // A different picture in the same place: everything after the text before it is recomputed.
        let other = PromptSegment.media(id: "xyz", tokens: 134, positions: 134)
        let changed = cache.reuse(for: [.text([1, 2]), other, .text([3, 4])])
        XCTAssertEqual(changed.keptPositions, 2)
        XCTAssertEqual(changed.resumeSegment, 1)

        // A picture without a hash is never trusted.
        let unnamed = PromptSegment.media(id: "", tokens: 134, positions: 134)
        var emptyIDCache = PromptCache()
        emptyIDCache.store(prompt: [.text([1]), unnamed], generated: [])
        XCTAssertEqual(emptyIDCache.reuse(for: [.text([1]), unnamed]).keptPositions, 1)
    }

    func testPromptCacheRecomputesTheLastTokenWhenNothingIsNew() {
        var cache = PromptCache()
        cache.store(prompt: [.text([1, 2, 3])], generated: [])
        // The identical prompt again: the model still needs a logit for the last token.
        let reuse = cache.reuse(for: [.text([1, 2, 3])])
        XCTAssertEqual(reuse.keptPositions, 2)
        XCTAssertEqual(reuse.resumeTokenOffset, 2)
    }

    func testPromptCacheEvaluatesAWholeTrailingImageAgain() {
        var cache = PromptCache()
        let image = PromptSegment.media(id: "abc", tokens: 134, positions: 134)
        cache.store(prompt: [.text([1, 2]), image], generated: [])
        let reuse = cache.reuse(for: [.text([1, 2]), image])
        XCTAssertEqual(reuse.keptPositions, 2)
        XCTAssertEqual(reuse.resumeSegment, 1)
        XCTAssertEqual(reuse.resumeTokenOffset, 0)
        XCTAssertEqual(PromptCache().reuse(for: []).keptPositions, 0)
    }

    func testPromptCacheStartsANewTextRunForTheReplyAfterAnImage() {
        var cache = PromptCache()
        let image = PromptSegment.media(id: "abc", tokens: 134, positions: 134)
        cache.store(prompt: [.text([1, 2]), image], generated: [7, 8])
        let reuse = cache.reuse(for: [.text([1, 2]), image, .text([7, 8, 9])])
        XCTAssertEqual(reuse.keptPositions, 2 + 134 + 2)
        XCTAssertEqual(reuse.resumeSegment, 2)
        XCTAssertEqual(reuse.resumeTokenOffset, 2)
    }

    func testPromptCacheEvaluatesTheLastTokenWhenThePromptEndsInsideTheCachedReply() {
        // The same prompt sent again: the cache holds the prompt and the previous reply, so the prompt is a
        // strict prefix of the cached text. Without a token to evaluate there is no logit, and the model
        // answered with nothing (found on the phone).
        var cache = PromptCache()
        cache.store(prompt: [.text([1, 2, 3, 4, 5])], generated: [6, 7, 8])
        let same = cache.reuse(for: [.text([1, 2, 3, 4, 5])])
        XCTAssertEqual(same.keptPositions, 4)
        XCTAssertEqual(same.resumeTokenOffset, 4)

        // A turn that goes on from the reply keeps the whole cache.
        let next = cache.reuse(for: [.text([1, 2, 3, 4, 5, 6, 7, 8, 9])])
        XCTAssertEqual(next.keptPositions, 8)
        XCTAssertEqual(next.resumeTokenOffset, 8)

        // Diverging inside the reply keeps only the common start.
        let diverge = cache.reuse(for: [.text([1, 2, 3, 4, 5, 6, 99])])
        XCTAssertEqual(diverge.keptPositions, 6)
        XCTAssertEqual(diverge.resumeTokenOffset, 6)
    }

    func testPromptCacheResetForgetsEverything() {
        var cache = PromptCache()
        cache.store(prompt: [.text([1, 2, 3])], generated: [4])
        XCTAssertEqual(cache.cachedPositions, 4)
        cache.reset()
        XCTAssertEqual(cache.reuse(for: [.text([1, 2, 3, 4])]).keptPositions, 0)
    }

    func testThinkingSwitchIsOnlyAppliedToTemplatesWithAThinkingMode() {
        let messages = [InferenceMessage(role: .user, parts: [.text("hello")])]
        let thinking = "{{ '<|im_start|>assistant\n<think>\n' }} ... </think>"
        let plain = "chatml"

        let off = TemplatePromptFormatter.format(messages, template: thinking, mediaMarker: "<m>", enableThinking: false)
        XCTAssertTrue(off.prompt.hasSuffix(TemplatePromptFormatter.closedThinkingBlock))

        // Not asked to switch it off: the prompt is left as the template wrote it.
        let unset = TemplatePromptFormatter.format(messages, template: thinking, mediaMarker: "<m>")
        XCTAssertFalse(unset.prompt.contains("</think>\n\n"))
        // Asked to think: the answer starts inside an open reasoning block, as the model's template does.
        let on = TemplatePromptFormatter.format(messages, template: thinking, mediaMarker: "<m>", enableThinking: true)
        XCTAssertTrue(on.prompt.hasSuffix(TemplatePromptFormatter.openThinkingBlock))
        XCTAssertFalse(on.prompt.hasSuffix(TemplatePromptFormatter.closedThinkingBlock))

        // A model without a thinking mode gets nothing added.
        let noThinking = TemplatePromptFormatter.format(messages, template: plain, mediaMarker: "<m>", enableThinking: false)
        XCTAssertFalse(noThinking.prompt.contains("<think>"))
        XCTAssertFalse(TemplatePromptFormatter.supportsThinkingSwitch(template: plain))
        XCTAssertFalse(TemplatePromptFormatter.supportsThinkingSwitch(template: nil))
        XCTAssertTrue(TemplatePromptFormatter.supportsThinkingSwitch(template: thinking))
    }

    func testGemma4ThinksOnlyWhenTheSystemTurnCarriesTheThinkingToken() {
        let user = InferenceMessage(role: .user, parts: [.text("hi")])
        let system = InferenceMessage(role: .system, parts: [.text("Be brief.")])

        let off = GemmaPromptFormatter.format([user], mediaMarker: "<m>")
        XCTAssertFalse(off.prompt.contains(GemmaPromptFormatter.thinkingToken))
        XCTAssertTrue(off.prompt.hasPrefix("<|turn>user\n"))

        let onWithoutSystem = GemmaPromptFormatter.format([user], mediaMarker: "<m>", enableThinking: true)
        XCTAssertTrue(onWithoutSystem.prompt.hasPrefix("<|turn>system\n<|think|><turn|>\n<|turn>user\n"))

        let onWithSystem = GemmaPromptFormatter.format([system, user], mediaMarker: "<m>", enableThinking: true)
        XCTAssertTrue(onWithSystem.prompt.hasPrefix("<|turn>system\n<|think|>Be brief.<turn|>\n"))

        // Asking for no thinking is the same as saying nothing: Gemma 4 does not think by default.
        let explicitOff = GemmaPromptFormatter.format([system, user], mediaMarker: "<m>", enableThinking: false)
        XCTAssertEqual(explicitOff.prompt, GemmaPromptFormatter.format([system, user], mediaMarker: "<m>").prompt)
    }
}
