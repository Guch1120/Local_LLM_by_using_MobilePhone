import Foundation
import Security

/// A model repository returned by the Hugging Face search API.
struct HuggingFaceModelSummary: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let downloads: Int
    let likes: Int
    /// Gated repositories need an access token whose account accepted the model's terms.
    let gated: Bool
    /// The task the model is published for, such as `text-generation` or `image-text-to-text`.
    let pipelineTag: String?

    private enum CodingKeys: String, CodingKey {
        case id, downloads, likes, gated
        case pipelineTag = "pipeline_tag"
    }

    init(id: String, downloads: Int = 0, likes: Int = 0, gated: Bool = false, pipelineTag: String? = nil) {
        self.id = id
        self.downloads = downloads
        self.likes = likes
        self.gated = gated
        self.pipelineTag = pipelineTag
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloads = (try? container.decode(Int.self, forKey: .downloads)) ?? 0
        likes = (try? container.decode(Int.self, forKey: .likes)) ?? 0
        pipelineTag = try? container.decode(String.self, forKey: .pipelineTag)
        // The API sends `false`, or the string "auto" or "manual".
        if let flag = try? container.decode(Bool.self, forKey: .gated) {
            gated = flag
        } else {
            gated = (try? container.decode(String.self, forKey: .gated)) != nil
        }
    }
}

/// What a model is used for, as a search filter. Only uses this app can run are offered.
enum ModelUse: String, CaseIterable, Identifiable, Sendable {
    case any
    case text
    case vision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "All"
        case .text: return "Text"
        case .vision: return "Image + text"
        }
    }

    /// Hugging Face task tags that belong to this use; empty means no filter.
    var pipelineTags: [String] {
        switch self {
        case .any: return []
        case .text: return ["text-generation"]
        case .vision: return ["image-text-to-text", "any-to-any"]
        }
    }

    /// The use a task tag stands for, or nil when this app cannot run that kind of model.
    static func supported(pipelineTag: String) -> ModelUse? {
        [ModelUse.text, .vision].first { $0.pipelineTags.contains(pipelineTag) }
    }
}

/// A model file (.gguf or .litertlm) inside a Hugging Face repository.
struct HuggingFaceFile: Identifiable, Sendable, Equatable {
    let path: String
    let sizeBytes: Int64

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    /// The model ID the app assigns after import: the lower-cased file name without its extension.
    var baseName: String { (fileName as NSString).deletingPathExtension }
    var isProjector: Bool { ModelManager.isProjector(URL(fileURLWithPath: fileName)) }
    /// Multi-token-prediction drafters ("mtp-...") only work next to their main model, which this
    /// app does not support; llama.cpp refuses to load them on their own.
    var isDrafter: Bool { fileName.lowercased().hasPrefix("mtp-") }
}

/// A rough "will it run" hint from the file size and the device's memory.
enum ModelFit: Sendable, Equatable {
    case comfortable
    case tight
    case tooLarge

    static func estimate(
        sizeBytes: Int64, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> ModelFit {
        let ratio = Double(sizeBytes) / Double(max(physicalMemory, 1))
        if ratio <= 0.45 { return .comfortable }
        if ratio <= 0.6 { return .tight }
        return .tooLarge
    }
}

enum HuggingFaceError: Error, LocalizedError, Equatable {
    case invalidRepository
    case unauthorized
    case notFound
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Enter a repository as owner/name and a file inside it."
        case .unauthorized:
            return "Hugging Face denied access. Gated or private repositories need an access token (Settings) "
                + "from an account that accepted the model's terms."
        case .notFound:
            return "The repository or file was not found on Hugging Face."
        case let .server(status):
            return "Hugging Face returned HTTP \(status)."
        }
    }
}

/// Read-only access to the public Hugging Face Hub API. Requests happen only when the user
/// searches or downloads; nothing about prompts, images or device use is sent.
struct HuggingFaceClient: Sendable {
    static let modelExtensions: Set<String> = ["gguf", "litertlm"]

    var token: String?
    var session: URLSession = .shared

    static func isValidRepository(_ repository: String) -> Bool {
        repository.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression
        ) != nil
    }

    static func searchURL(query: String, ggufOnly: Bool, pipelineTag: String? = nil, limit: Int = 40) -> URL? {
        var components = URLComponents(string: "https://huggingface.co/api/models")
        var items = [
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "search", value: trimmed)) }
        if ggufOnly { items.append(URLQueryItem(name: "filter", value: "gguf")) }
        if let pipelineTag { items.append(URLQueryItem(name: "pipeline_tag", value: pipelineTag)) }
        components?.queryItems = items
        return components?.url
    }

    static func treeURL(repository: String, revision: String = "main") -> URL? {
        guard isValidRepository(repository), isValidRevision(revision) else { return nil }
        var components = URLComponents(string: "https://huggingface.co")
        components?.path = "/api/models/\(repository)/tree/\(revision)"
        components?.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        return components?.url
    }

    static func downloadURL(repository: String, revision: String = "main", path: String) -> URL? {
        guard isValidRepository(repository), isValidRevision(revision), isValidPath(path) else { return nil }
        var components = URLComponents(string: "https://huggingface.co")
        components?.path = "/\(repository)/resolve/\(revision)/\(path)"
        return components?.url
    }

    private static func isValidRevision(_ revision: String) -> Bool {
        revision.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }

    private static func isValidPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let pathExtension = (path as NSString).pathExtension.lowercased()
        return !parts.isEmpty && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            && modelExtensions.contains(pathExtension)
    }

    /// Model files of a repository listing: models first by size, projectors (mmproj) last.
    static func decodeFiles(_ data: Data) throws -> [HuggingFaceFile] {
        struct Entry: Decodable {
            struct LargeFile: Decodable { let size: Int64? }
            let type: String
            let path: String
            let size: Int64?
            let lfs: LargeFile?
        }
        return try JSONDecoder().decode([Entry].self, from: data)
            .filter { $0.type == "file" && modelExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
            .map { HuggingFaceFile(path: $0.path, sizeBytes: $0.lfs?.size ?? $0.size ?? 0) }
            .sorted { lhs, rhs in
                if lhs.isProjector != rhs.isProjector { return !lhs.isProjector }
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
                return lhs.path < rhs.path
            }
    }

    /// Most downloaded repositories first. A use with several task tags is searched once per tag.
    func search(query: String, ggufOnly: Bool, use: ModelUse = .any) async throws -> [HuggingFaceModelSummary] {
        let tags: [String?] = use.pipelineTags.isEmpty ? [nil] : use.pipelineTags
        var found: [HuggingFaceModelSummary] = []
        for tag in tags {
            guard let url = Self.searchURL(query: query, ggufOnly: ggufOnly, pipelineTag: tag) else {
                throw HuggingFaceError.invalidRepository
            }
            found += try JSONDecoder().decode([HuggingFaceModelSummary].self, from: try await data(from: url))
        }
        return Self.merged(found)
    }

    /// Removes repositories listed twice and sorts by downloads.
    static func merged(_ results: [HuggingFaceModelSummary], limit: Int = 40) -> [HuggingFaceModelSummary] {
        var seen = Set<String>()
        return Array(
            results.filter { seen.insert($0.id).inserted }
                .sorted { $0.downloads > $1.downloads }
                .prefix(limit)
        )
    }

    func modelFiles(repository: String, revision: String = "main") async throws -> [HuggingFaceFile] {
        guard let url = Self.treeURL(repository: repository, revision: revision) else {
            throw HuggingFaceError.invalidRepository
        }
        return try Self.decodeFiles(try await data(from: url))
    }

    private func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data
        case 401, 403: throw HuggingFaceError.unauthorized
        case 404: throw HuggingFaceError.notFound
        case let status: throw HuggingFaceError.server(status)
        }
    }
}

/// Optional Hugging Face access token for gated or private repositories, kept in Keychain.
struct HuggingFaceTokenStore: Sendable {
    private let service = "jp.localai.iphone-server"
    private let account = "huggingface-token"

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// Stores the token; an empty token removes it.
    func save(_ token: String) throws {
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(deleteStatus)
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var query = baseQuery
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw APIKeyStoreError.keychain(addStatus) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
