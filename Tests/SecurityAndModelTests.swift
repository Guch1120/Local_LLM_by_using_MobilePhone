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
            XCTAssertEqual(error.localizedDescription, "Only .litertlm model files can be imported.")
        }
    }
}
