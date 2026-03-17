import Foundation
import Security

struct StoredCredentials: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]

    var hasRefreshToken: Bool {
        guard let refreshToken else { return false }
        return refreshToken.isEmpty == false
    }

    func needsRefresh(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard hasRefreshToken, let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }
}

struct StoredCredentialsStore {
    let accountId: String
    let keychainService: String

    // Legacy file URLs retained only for one-time migration
    private let legacyCredentialsFileURL: URL
    private let legacyTokenFileURL: URL

    init(
        accountId: String,
        directoryURL: URL = AppPaths.configDirectoryURL,
        keychainService: String = "claude-usage-bar"
    ) {
        self.accountId = accountId
        self.keychainService = keychainService
        self.legacyCredentialsFileURL = directoryURL.appendingPathComponent("credentials-\(accountId).json")
        self.legacyTokenFileURL = directoryURL.appendingPathComponent("token")
    }

    func save(_ credentials: StoredCredentials) throws {
        let data = try Self.encoder.encode(credentials)
        // Delete existing entry before adding (update pattern)
        keychainDelete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func load(defaultScopes: [String]) -> StoredCredentials? {
        // 1. Try Keychain
        if let data = keychainLoad(),
           let credentials = try? Self.decoder.decode(StoredCredentials.self, from: data) {
            return credentials
        }

        // 2. Migrate from per-account JSON file (credentials-{id}.json)
        if let data = try? Data(contentsOf: legacyCredentialsFileURL),
           let credentials = try? Self.decoder.decode(StoredCredentials.self, from: data) {
            try? save(credentials)
            try? FileManager.default.removeItem(at: legacyCredentialsFileURL)
            return credentials
        }

        // 3. Migrate from legacy raw token file
        if let data = try? Data(contentsOf: legacyTokenFileURL),
           let token = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            let credentials = StoredCredentials(
                accessToken: token,
                refreshToken: nil,
                expiresAt: nil,
                scopes: defaultScopes
            )
            try? save(credentials)
            try? FileManager.default.removeItem(at: legacyTokenFileURL)
            return credentials
        }

        return nil
    }

    func delete() {
        keychainDelete()
        try? FileManager.default.removeItem(at: legacyCredentialsFileURL)
        try? FileManager.default.removeItem(at: legacyTokenFileURL)
    }

    // MARK: - Keychain Helpers

    private func keychainLoad() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func keychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: accountId
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case saveFailed(OSStatus)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
