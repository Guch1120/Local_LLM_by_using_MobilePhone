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

actor LogService {
    private let capacity: Int
    private var entries: [LogEntry] = []

    init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    func write(_ level: LogLevel, event: String, requestID: String? = nil, details: String? = nil) {
        entries.append(LogEntry(id: UUID(), timestamp: Date(), level: level, event: event, requestID: requestID, details: details))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func list(limit: Int = 200) -> [LogEntry] {
        Array(entries.suffix(max(1, min(limit, capacity))).reversed())
    }
}
