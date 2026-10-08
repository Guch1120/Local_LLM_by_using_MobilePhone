import Foundation

extension InstalledModel {
    /// Forgets adapters whose file is gone (for example deleted over USB), and the selection of such an adapter.
    func droppingMissingAdapters(_ fileManager: FileManager) -> InstalledModel {
        var copy = self
        copy.adapters = adapters?.filter { fileManager.fileExists(atPath: $0.path) }
        if copy.activeAdapter == nil { copy.activeAdapterID = nil }
        return copy
    }
}

extension ModelManager {
    /// Registers a LoRA adapter file for a llama.cpp model and returns that model. The adapter stays inactive until selected.
    /// - Parameter targetID: the model the adapter belongs to. Without it the adapter goes to the newest installed model of
    ///   the adapter's architecture, or to the newest llama.cpp model when none matches.
    func importAdapter(from sourceURL: URL, moveSource: Bool, targetID: String?) throws -> InstalledModel {
        let index = try adapterTargetIndex(for: sourceURL, targetID: targetID)
        let model = installedModels[index]
        let name = sourceURL.deletingPathExtension().lastPathComponent
        let adapterID = Self.safeIdentifier(name)
        let destination = directoryURL.appendingPathComponent("\(model.id).adapter-\(adapterID).gguf")
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        if moveSource {
            try fileManager.moveItem(at: sourceURL, to: destination)
        } else {
            try fileManager.copyItem(at: sourceURL, to: destination)
        }
        var excludedDestination = destination
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        try? excludedDestination.setResourceValues(backupValues)

        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let adapter = ModelAdapter(id: adapterID, name: name, path: destination.path, sizeBytes: Int64(size), importedAt: Date())
        let previous = model.adapters
        installedModels[index].adapters = (previous ?? []).filter { $0.id != adapterID } + [adapter]
        do {
            try persist()
        } catch {
            installedModels[index].adapters = previous
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return installedModels[index]
    }

    /// Chooses the adapter a model applies when it loads; nil selects none.
    func setActiveAdapter(modelID: String, adapterID: String?) throws {
        guard let index = installedModels.firstIndex(where: { $0.id == modelID }) else {
            throw ModelImportError.adapterTargetMissing
        }
        if let adapterID, installedModels[index].adapters?.contains(where: { $0.id == adapterID }) != true {
            throw ModelImportError.adapterTargetMissing
        }
        guard installedModels[index].activeAdapterID != adapterID else { return }
        installedModels[index].activeAdapterID = adapterID
        try persist()
    }

    func removeAdapter(modelID: String, adapterID: String) throws {
        guard let index = installedModels.firstIndex(where: { $0.id == modelID }),
              let adapter = installedModels[index].adapters?.first(where: { $0.id == adapterID }) else { return }
        if fileManager.fileExists(atPath: adapter.path) { try fileManager.removeItem(atPath: adapter.path) }
        installedModels[index].adapters?.removeAll { $0.id == adapterID }
        if installedModels[index].activeAdapterID == adapterID { installedModels[index].activeAdapterID = nil }
        try persist()
    }

    private func adapterTargetIndex(for url: URL, targetID: String?) throws -> Int {
        let candidates = installedModels.indices.filter { installedModels[$0].backend == "llama.cpp" }
        if let targetID {
            guard let match = candidates.first(where: { installedModels[$0].id == targetID }) else {
                throw ModelImportError.adapterTargetMissing
            }
            return match
        }
        let newestFirst = candidates.sorted { installedModels[$0].importedAt > installedModels[$1].importedAt }
        if let architecture = GGUFMetadata.read(from: url)?.architecture,
           let match = newestFirst.first(where: { GGUFMetadata.read(from: installedModels[$0].fileURL)?.architecture == architecture }) {
            return match
        }
        guard let newest = newestFirst.first else { throw ModelImportError.adapterWithoutModel }
        return newest
    }

    static func safeIdentifier(_ name: String) -> String {
        let safe = name.lowercased().replacingOccurrences(of: "[^a-z0-9._-]", with: "-", options: .regularExpression)
        return safe.isEmpty ? "adapter" : safe
    }
}
