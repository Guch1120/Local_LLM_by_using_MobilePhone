import Foundation

enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

struct LogEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let event: String
    let requestID: String?
    let details: String?
}

struct LogPersistenceStatus: Codable, Sendable {
    let enabled: Bool
    let healthy: Bool
    let entryCount: Int
    let lastError: String?
}

private struct LogArchive: Codable {
    let schemaVersion: Int
    let entries: [LogEntry]
}

actor LogService {
    private let capacity: Int
    private let persistenceURL: URL?
    private var entries: [LogEntry] = []
    private var persistenceError: String?

    init(capacity: Int = 500, persistenceURL: URL? = nil) {
        self.capacity = max(1, capacity)
        self.persistenceURL = persistenceURL
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else { return }

        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(LogArchive.self, from: data)
            guard archive.schemaVersion == 1 else {
                throw CocoaError(.coderReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "Unsupported log archive version."])
            }
            entries = Array(archive.entries.suffix(self.capacity))
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    func write(_ level: LogLevel, event: String, requestID: String? = nil, details: String? = nil) {
        entries.append(LogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            event: String(event.prefix(120)),
            requestID: requestID.map { String($0.prefix(160)) },
            details: details.map { String($0.prefix(2_000)) }
        ))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        persist()
    }

    func list(limit: Int = 200) -> [LogEntry] {
        Array(entries.suffix(max(1, min(limit, capacity))).reversed())
    }

    func persistenceStatus() -> LogPersistenceStatus {
        LogPersistenceStatus(
            enabled: persistenceURL != nil,
            healthy: persistenceURL == nil || persistenceError == nil,
            entryCount: entries.count,
            lastError: persistenceError
        )
    }

    private func persist() {
        guard let persistenceURL else { return }
        do {
            let directory = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var excludedDirectory = directory
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? excludedDirectory.setResourceValues(resourceValues)

            let archive = LogArchive(schemaVersion: 1, entries: entries)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(archive)
            try data.write(to: persistenceURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}
