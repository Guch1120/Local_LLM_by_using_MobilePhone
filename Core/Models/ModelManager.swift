import CryptoKit
import Foundation

struct InstalledModel: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let backend: String
    let path: String
    let sha256: String
    let sizeBytes: Int64
    let modalities: [String]
    let importedAt: Date

    var fileURL: URL { URL(fileURLWithPath: path) }

    /// The app container path changes across reinstalls, so resolve the file by name.
    func relocated(to directory: URL) -> InstalledModel {
        InstalledModel(
            id: id,
            name: name,
            backend: backend,
            path: directory.appendingPathComponent(fileURL.lastPathComponent).path,
            sha256: sha256,
            sizeBytes: sizeBytes,
            modalities: modalities,
            importedAt: importedAt
        )
    }
}

enum ModelImportError: Error, LocalizedError {
    case unsupportedFile

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "Only .litertlm model files can be imported."
        }
    }
}

actor ModelManager {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let registryURL: URL
    private let inboxURL: URL?
    private var installedModels: [InstalledModel] = []

    /// - Parameter inboxURL: Folder scanned by `importInbox()`. Defaults to the app's
    ///   Documents folder, which is reachable over USB and in the Files app.
    init(directoryURL: URL? = nil, inboxURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = directoryURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Models", isDirectory: true)
        self.directoryURL = support
        self.inboxURL = inboxURL ?? (directoryURL == nil ? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first : nil)
        registryURL = support.appendingPathComponent("models.json")
        try? fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: registryURL),
           let models = try? JSONDecoder().decode([InstalledModel].self, from: data) {
            installedModels = models
                .map { $0.relocated(to: support) }
                .filter { fileManager.fileExists(atPath: $0.path) }
        }
    }

    func list() -> [InstalledModel] { installedModels }

    /// Moves `.litertlm` files from the inbox folder into Application Support and registers them.
    func importInbox() throws -> [InstalledModel] {
        guard let inboxURL,
              let contents = try? fileManager.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return try contents
            .filter { $0.pathExtension.lowercased() == "litertlm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try importModel(from: $0, moveSource: true) }
    }

    func importModel(from sourceURL: URL, moveSource: Bool = false) throws -> InstalledModel {
        guard sourceURL.pathExtension.lowercased() == "litertlm" else {
            throw ModelImportError.unsupportedFile
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let fileName = sourceURL.lastPathComponent
        let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let safeName = name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let temporaryURL = directoryURL.appendingPathComponent(".import-\(UUID().uuidString).litertlm")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        if moveSource {
            try fileManager.moveItem(at: sourceURL, to: temporaryURL)
        } else {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        }
        let digest: String
        do {
            digest = try Self.sha256(fileURL: temporaryURL)
        } catch {
            // Hand a moved file back instead of letting the cleanup delete it.
            if moveSource { try? fileManager.moveItem(at: temporaryURL, to: sourceURL) }
            throw error
        }
        if let existing = installedModels.first(where: { $0.sha256 == digest }) {
            return existing
        }

        let baseIdentifier = safeName.isEmpty ? "model" : safeName.lowercased()
        let identifier = installedModels.contains(where: { $0.id == baseIdentifier })
            ? "\(baseIdentifier)-\(digest.prefix(10))"
            : baseIdentifier
        let destination = directoryURL.appendingPathComponent("\(identifier).litertlm")
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        // Multi-gigabyte weights can be re-imported; keep them out of device backups.
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        var excludedDestination = destination
        try? excludedDestination.setResourceValues(backupValues)

        let values: URLResourceValues
        do {
            values = try destination.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        let model = InstalledModel(
            id: identifier,
            name: name,
            backend: "litert-lm",
            path: destination.path,
            sha256: digest,
            sizeBytes: Int64(values.fileSize ?? 0),
            modalities: ["text", "image"],
            importedAt: Date()
        )
        installedModels.append(model)
        do {
            try persist()
        } catch {
            installedModels.removeAll { $0.id == model.id }
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return model
    }

    func removeModel(id: String) throws {
        guard let model = installedModels.first(where: { $0.id == id }) else { return }
        if fileManager.fileExists(atPath: model.path) { try fileManager.removeItem(atPath: model.path) }
        installedModels.removeAll { $0.id == id }
        try persist()
    }

    func model(id: String) -> InstalledModel? {
        installedModels.first { $0.id == id }
    }

    func verifyModel(id: String) throws -> Bool {
        guard let model = installedModels.first(where: { $0.id == id }),
              fileManager.fileExists(atPath: model.path) else { return false }
        return try Self.sha256(fileURL: model.fileURL) == model.sha256
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(installedModels).write(to: registryURL, options: .atomic)
    }

    private static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty {
            hasher.update(data: block)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
