import Foundation
import Security

enum APIKeyStoreError: Error {
    case keychain(OSStatus)
    case randomGeneration(OSStatus)
}

struct APIKeyStore {
    private let service = "jp.localai.iphone-server"
    private let account = "api-bearer-token"

    func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        return try regenerate()
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw APIKeyStoreError.keychain(status)
        }
        return token
    }

    @discardableResult
    func regenerate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw APIKeyStoreError.randomGeneration(status) }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let data = Data(token.utf8)
        let deleteStatus = SecItemDelete(baseQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(deleteStatus)
        }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw APIKeyStoreError.keychain(addStatus) }
        return token
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
