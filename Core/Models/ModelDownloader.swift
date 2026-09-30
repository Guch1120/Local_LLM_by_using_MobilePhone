import Foundation

/// One model file being fetched from Hugging Face.
struct ModelDownload: Identifiable, Sendable, Equatable {
    enum State: String, Sendable {
        case queued
        case downloading
        case importing
        case completed
        case failed
    }

    let id: UUID
    let repository: String
    let revision: String
    let path: String
    var state: State
    var receivedBytes: Int64
    var totalBytes: Int64
    var error: String?
    /// ID of the installed model once the file has been imported.
    var modelID: String?

    var fileName: String { (path as NSString).lastPathComponent }
    var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
    var isActive: Bool { state == .queued || state == .downloading || state == .importing }
}

enum ModelDownloadError: Error, LocalizedError {
    case insufficientSpace(needed: Int64, available: Int64)
    case http(Int)
    case importUnavailable

    var errorDescription: String? {
        switch self {
        case let .insufficientSpace(needed, available):
            let formatter = ByteCountFormatter()
            return "Not enough free storage: \(formatter.string(fromByteCount: needed)) needed, "
                + "\(formatter.string(fromByteCount: available)) available."
        case .http(401), .http(403):
            return HuggingFaceError.unauthorized.errorDescription
        case .http(404):
            return HuggingFaceError.notFound.errorDescription
        case let .http(status):
            return "The download failed with HTTP \(status)."
        case .importUnavailable:
            return "The downloaded file could not be imported."
        }
    }
}

/// Downloads model files one at a time and hands each finished file to `importer`.
/// Downloads run only while the app is in the foreground, like the server itself.
@MainActor
final class ModelDownloader: NSObject {
    private(set) var downloads: [ModelDownload] = [] {
        didSet { onChange?(downloads) }
    }

    var onChange: (@MainActor ([ModelDownload]) -> Void)?
    /// Imports a finished file and returns the ID of the installed model.
    var importer: (@MainActor (URL) async throws -> String)?
    var tokenProvider: @MainActor () -> String? = { nil }

    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var lastProgressUpdate = Date.distantPast
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Queues a file. Asking again for a file that is already queued or running returns that entry.
    @discardableResult
    func enqueue(repository: String, revision: String = "main", path: String, sizeBytes: Int64) throws -> ModelDownload {
        guard HuggingFaceClient.downloadURL(repository: repository, revision: revision, path: path) != nil else {
            throw HuggingFaceError.invalidRepository
        }
        if let existing = downloads.first(where: { $0.repository == repository && $0.path == path && $0.isActive }) {
            return existing
        }
        try Self.checkFreeSpace(for: sizeBytes)
        for stale in downloads where stale.repository == repository && stale.path == path {
            resumeData[stale.id] = nil
        }
        downloads.removeAll { $0.repository == repository && $0.path == path }
        let download = ModelDownload(
            id: UUID(), repository: repository, revision: revision, path: path,
            state: .queued, receivedBytes: 0, totalBytes: sizeBytes
        )
        downloads.append(download)
        startNextIfIdle()
        return download
    }

    /// Cancels an active download or clears a finished one from the list.
    func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        resumeData[id] = nil
        downloads.removeAll { $0.id == id }
        startNextIfIdle()
    }

    /// Puts a failed download back in the queue; it resumes where it stopped when possible.
    func retry(_ id: UUID) {
        update(id) { download in
            guard download.state == .failed else { return }
            download.state = .queued
            download.error = nil
        }
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard !downloads.contains(where: { $0.state == .downloading || $0.state == .importing }),
              let next = downloads.first(where: { $0.state == .queued }) else { return }
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: next.id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            guard let url = HuggingFaceClient.downloadURL(
                repository: next.repository, revision: next.revision, path: next.path
            ) else {
                update(next.id) { $0.state = .failed; $0.error = HuggingFaceError.invalidRepository.errorDescription }
                return
            }
            var request = URLRequest(url: url)
            if let token = tokenProvider(), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = "\(next.id.uuidString)\n\(next.fileName)"
        tasks[next.id] = task
        update(next.id) { $0.state = .downloading }
        task.resume()
    }

    private func update(_ id: UUID, _ change: (inout ModelDownload) -> Void) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        var download = downloads[index]
        change(&download)
        if download != downloads[index] { downloads[index] = download }
    }

    private func updateProgress(_ id: UUID, received: Int64, expected: Int64) {
        // The delegate reports progress many times per second; redraw a few times per second.
        guard Date().timeIntervalSince(lastProgressUpdate) >= 0.3 else { return }
        lastProgressUpdate = Date()
        update(id) { download in
            guard download.state == .downloading else { return }
            download.receivedBytes = received
            if expected > 0 { download.totalBytes = expected }
        }
    }

    private func finish(_ id: UUID, result: Result<URL, Error>) async {
        tasks[id] = nil
        switch result {
        case let .failure(error):
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        case let .success(url):
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            guard downloads.contains(where: { $0.id == id }) else { break }
            update(id) { download in
                download.state = .importing
                if download.totalBytes > 0 { download.receivedBytes = download.totalBytes }
            }
            do {
                guard let importer else { throw ModelDownloadError.importUnavailable }
                let modelID = try await importer(url)
                update(id) { $0.state = .completed; $0.modelID = modelID }
            } catch {
                update(id) { $0.state = .failed; $0.error = error.localizedDescription }
            }
        }
        startNextIfIdle()
    }

    private func fail(_ id: UUID, error: Error, resumeData data: Data?) {
        tasks[id] = nil
        // A download removed by the user has no entry any more; its cancellation is not a failure.
        guard downloads.contains(where: { $0.id == id }) else { return }
        resumeData[id] = data
        update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        startNextIfIdle()
    }

    private static func checkFreeSpace(for sizeBytes: Int64) throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard sizeBytes > 0, let available = values?.volumeAvailableCapacityForImportantUsage else { return }
        // Leave headroom so the phone does not end up with a full disk.
        let needed = sizeBytes + 500_000_000
        if available < needed {
            throw ModelDownloadError.insufficientSpace(needed: needed, available: available)
        }
    }

    private nonisolated static func describe(_ task: URLSessionTask) -> (id: UUID, fileName: String)? {
        guard let parts = task.taskDescription?.split(separator: "\n", maxSplits: 1), parts.count == 2,
              let id = UUID(uuidString: String(parts[0])) else { return nil }
        return (id, String(parts[1]))
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let info = Self.describe(downloadTask) else { return }
        Task { @MainActor in
            self.updateProgress(info.id, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let info = Self.describe(downloadTask) else { return }
        // The temporary file is deleted when this method returns, so move it before leaving.
        let result: Result<URL, Error>
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw ModelDownloadError.http(status) }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("hf-\(info.id.uuidString)", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(info.fileName)
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(destination)
        } catch {
            result = .failure(error)
        }
        Task { @MainActor in
            await self.finish(info.id, result: result)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let info = Self.describe(task) else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            self.fail(info.id, error: error, resumeData: resumeData)
        }
    }
}
