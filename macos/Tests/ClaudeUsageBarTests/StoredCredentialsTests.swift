import XCTest
import Security
@testable import ClaudeUsageBar

final class StoredCredentialsTests: XCTestCase {
    private var keychainService: String!
    private var directoryURL: URL!

    override func setUp() {
        super.setUp()
        keychainService = "claude-usage-bar-test-\(UUID().uuidString)"
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Remove all Keychain items created by this test
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService!
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: directoryURL)
        super.tearDown()
    }

    // MARK: - Keychain Save / Load

    func testSavesAndLoadsFromKeychain() throws {
        let store = makeStore()
        let credentials = StoredCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date(timeIntervalSince1970: 1_741_194_400),
            scopes: ["user:profile", "user:inference"]
        )

        try store.save(credentials)
        let loaded = try XCTUnwrap(store.load(defaultScopes: []))
        XCTAssertEqual(loaded, credentials)
    }

    func testOverwritesExistingKeychainEntry() throws {
        let store = makeStore()
        let first = StoredCredentials(accessToken: "first", refreshToken: nil, expiresAt: nil, scopes: [])
        let second = StoredCredentials(accessToken: "second", refreshToken: "r", expiresAt: nil, scopes: ["s"])

        try store.save(first)
        try store.save(second)

        let loaded = try XCTUnwrap(store.load(defaultScopes: []))
        XCTAssertEqual(loaded, second)
    }

    func testDeleteRemovesKeychainEntry() throws {
        let store = makeStore()
        let credentials = StoredCredentials(accessToken: "tok", refreshToken: nil, expiresAt: nil, scopes: [])
        try store.save(credentials)

        store.delete()

        XCTAssertNil(store.load(defaultScopes: []))
    }

    func testTwoAccountsAreIsolatedInKeychain() throws {
        let store1 = makeStore(accountId: "account-1")
        let store2 = makeStore(accountId: "account-2")
        let cred1 = StoredCredentials(accessToken: "token-1", refreshToken: nil, expiresAt: nil, scopes: [])
        let cred2 = StoredCredentials(accessToken: "token-2", refreshToken: nil, expiresAt: nil, scopes: [])

        try store1.save(cred1)
        try store2.save(cred2)

        XCTAssertEqual(store1.load(defaultScopes: [])?.accessToken, "token-1")
        XCTAssertEqual(store2.load(defaultScopes: [])?.accessToken, "token-2")

        store1.delete()
        XCTAssertNil(store1.load(defaultScopes: []))
        XCTAssertEqual(store2.load(defaultScopes: [])?.accessToken, "token-2")
    }

    // MARK: - Legacy Migration

    func testMigratesLegacyJsonFileToKeychain() throws {
        let accountId = "migrate-account"
        let store = makeStore(accountId: accountId)

        let legacyCredentials = StoredCredentials(
            accessToken: "migrated-token",
            refreshToken: "migrated-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_741_194_400),
            scopes: ["user:profile"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(legacyCredentials)
        try data.write(to: directoryURL.appendingPathComponent("credentials-\(accountId).json"), options: .atomic)

        let loaded = try XCTUnwrap(store.load(defaultScopes: []))
        XCTAssertEqual(loaded, legacyCredentials)

        // File should be deleted after migration
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent("credentials-\(accountId).json").path
        ))

        // Subsequent load should come from Keychain
        let loadedAgain = try XCTUnwrap(store.load(defaultScopes: []))
        XCTAssertEqual(loadedAgain, legacyCredentials)
    }

    func testMigratesLegacyRawTokenFileToKeychain() throws {
        let store = makeStore()
        try "legacy-access-token".write(to: directoryURL.appendingPathComponent("token"), atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(store.load(defaultScopes: UsageService.defaultOAuthScopes))

        XCTAssertEqual(loaded.accessToken, "legacy-access-token")
        XCTAssertNil(loaded.refreshToken)
        XCTAssertNil(loaded.expiresAt)
        XCTAssertEqual(loaded.scopes, UsageService.defaultOAuthScopes)

        // Token file should be deleted after migration
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directoryURL.appendingPathComponent("token").path
        ))
    }

    func testJsonFileTakesPrecedenceOverTokenFile() throws {
        let accountId = "precedence-account"
        let store = makeStore(accountId: accountId)

        // Write both files — JSON should win
        let jsonCredentials = StoredCredentials(
            accessToken: "json-token",
            refreshToken: "r",
            expiresAt: nil,
            scopes: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(jsonCredentials)
        try data.write(to: directoryURL.appendingPathComponent("credentials-\(accountId).json"), options: .atomic)
        try "raw-token".write(to: directoryURL.appendingPathComponent("token"), atomically: true, encoding: .utf8)

        let loaded = try XCTUnwrap(store.load(defaultScopes: []))
        XCTAssertEqual(loaded.accessToken, "json-token")
    }

    // MARK: - Helpers

    private func makeStore(accountId: String = "test-account") -> StoredCredentialsStore {
        StoredCredentialsStore(accountId: accountId, directoryURL: directoryURL, keychainService: keychainService)
    }
}
