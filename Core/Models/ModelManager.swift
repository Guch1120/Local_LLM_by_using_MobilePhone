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
    /// Multimodal projector (mmproj) for llama.cpp GGUF models, if one was imported.
    var projectorPath: String?

    var fileURL: URL { URL(fileURLWithPath: path) }
    var projectorURL: URL? { projectorPath.map { URL(fileURLWithPath: $0) } }

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
            importedAt: importedAt,
            projectorPath: projectorURL.map { directory.appendingPathComponent($0.lastPathComponent).path }
        )
    }
}

enum ModelImportError: Error, LocalizedError {
    case unsupportedFile
    case projectorWithoutModel

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "Only .litertlm or .gguf model files can be imported."
        case .projectorWithoutModel:
            return "Import the GGUF model before its mmproj projector file."
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

    private static let supportedExtensions: Set<String> = ["litertlm", "gguf"]

    /// A GGUF file whose name contains "mmproj" is a multimodal projector, not a model.
    static func isProjector(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gguf" && url.lastPathComponent.lowercased().contains("mmproj")
    }

    /// Moves model files from the inbox folder into Application Support and registers them.
    /// Models are imported before projectors so a projector can attach to its model.
    func importInbox() throws -> [InstalledModel] {
        guard let inboxURL,
              let contents = try? fileManager.contentsOfDirectory(
                at: inboxURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              )
        else { return [] }
        return try Self.importOrder(contents).map { try importModel(from: $0, moveSource: true) }
    }

    /// Supported files, models first and projectors last, each group by name.
    static func importOrder(_ urls: [URL]) -> [URL] {
        urls
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let lhsProjector = isProjector(lhs), rhsProjector = isProjector(rhs)
                if lhsProjector != rhsProjector { return !lhsProjector }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
    }

    func importModel(from sourceURL: URL, moveSource: Bool = false) throws -> InstalledModel {
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else {
            throw ModelImportError.unsupportedFile
        }
        if Self.isProjector(sourceURL) {
            return try importProjector(from: sourceURL, moveSource: moveSource)
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let fileName = sourceURL.lastPathComponent
        let name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let safeName = name.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        let temporaryURL = directoryURL.appendingPathComponent(".import-\(UUID().uuidString).\(fileExtension)")
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
        let destination = directoryURL.appendingPathComponent("\(identifier).\(fileExtension)")
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
            backend: fileExtension == "gguf" ? "llama.cpp" : "litert-lm",
            path: destination.path,
            sha256: digest,
            sizeBytes: Int64(values.fileSize ?? 0),
            modalities: fileExtension == "gguf" ? ["text"] : ["text", "image"],
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

    /// Attaches a projector to the most recently imported GGUF model.
    private func importProjector(from sourceURL: URL, moveSource: Bool) throws -> InstalledModel {
        guard let index = installedModels.indices
            .filter({ installedModels[$0].backend == "llama.cpp" })
            .max(by: { installedModels[$0].importedAt < installedModels[$1].importedAt })
        else { throw ModelImportError.projectorWithoutModel }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        let target = installedModels[index]
        let destination = directoryURL.appendingPathComponent("\(target.id).mmproj.gguf")
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        if moveSource {
            try fileManager.moveItem(at: sourceURL, to: destination)
        } else {
            try fileManager.copyItem(at: sourceURL, to: destination)
        }
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        var excludedDestination = destination
        try? excludedDestination.setResourceValues(backupValues)

        installedModels[index] = InstalledModel(
            id: target.id,
            name: target.name,
            backend: target.backend,
            path: target.path,
            sha256: target.sha256,
            sizeBytes: target.sizeBytes,
            modalities: ["text", "image"],
            importedAt: target.importedAt,
            projectorPath: destination.path
        )
        try persist()
        return installedModels[index]
    }

    func removeModel(id: String) throws {
        guard let model = installedModels.first(where: { $0.id == id }) else { return }
        if fileManager.fileExists(atPath: model.path) { try fileManager.removeItem(atPath: model.path) }
        if let projector = model.projectorPath, fileManager.fileExists(atPath: projector) {
            try fileManager.removeItem(atPath: projector)
        }
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
        // Drain each block's autoreleased buffer; otherwise hashing a multi-gigabyte model
        // accumulates the whole file in memory and reads start failing under pressure.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty else { return false }
            hasher.update(data: block)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
