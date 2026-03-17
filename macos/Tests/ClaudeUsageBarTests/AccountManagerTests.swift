import XCTest
import Security
@testable import ClaudeUsageBar

final class AccountEntryTests: XCTestCase {
    func testDisplayNamePrefersAlias() {
        let entry = AccountEntry(alias: "Work", email: "work@example.com")
        XCTAssertEqual(entry.displayName(), "Work")
    }

    func testDisplayNameFallsBackToEmail() {
        let entry = AccountEntry(alias: nil, email: "me@example.com")
        XCTAssertEqual(entry.displayName(), "me@example.com")
    }

    func testDisplayNameFallsBackToAccountWhenEmpty() {
        let entry = AccountEntry(alias: nil, email: nil)
        XCTAssertEqual(entry.displayName(), "Account")
    }

    func testDisplayNameIgnoresEmptyAlias() {
        let entry = AccountEntry(alias: "", email: "me@example.com")
        XCTAssertEqual(entry.displayName(), "me@example.com")
    }

    func testDisplayNameEmojiAlias() {
        let entry = AccountEntry(alias: "🏢", email: "work@example.com")
        XCTAssertEqual(entry.displayName(), "🏢")
    }
}

@MainActor
final class AccountManagerTests: XCTestCase {
    private var directoryURL: URL!
    private var keychainService: String!

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

    // MARK: - Initial State

    func testStartsEmptyWhenNoAccountsFile() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        XCTAssertTrue(manager.accounts.isEmpty)
        XCTAssertNil(manager.activeAccountId)
    }

    func testLoadsPersistedAccounts() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        let id = manager.accounts[0].id

        let manager2 = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        XCTAssertEqual(manager2.accounts.count, 1)
        XCTAssertEqual(manager2.accounts[0].id, id)
        XCTAssertEqual(manager2.activeAccountId, id)
    }

    // MARK: - Add / Remove

    func testAddAccountCreatesEntry() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertNotNil(manager.activeAccountId)
        XCTAssertEqual(manager.activeAccountId, manager.accounts[0].id)
    }

    func testAddMultipleAccountsSwitchesActiveToNewest() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        let firstId = manager.accounts[0].id
        manager.addAccount(startOAuth: false)
        XCTAssertEqual(manager.accounts.count, 2)
        XCTAssertNotEqual(manager.activeAccountId, firstId)
    }

    func testRemoveAccountDeletesEntry() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        let id = manager.accounts[0].id
        manager.removeAccount(id: id)
        XCTAssertTrue(manager.accounts.isEmpty)
        XCTAssertNil(manager.activeAccountId)
    }

    func testRemoveActiveAccountSwitchesToFirstRemaining() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        let firstId = manager.accounts[0].id
        manager.addAccount(startOAuth: false)
        let secondId = manager.accounts[1].id

        manager.activeAccountId = secondId
        manager.removeAccount(id: secondId)

        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.activeAccountId, firstId)
    }

    func testRemoveNonActiveAccountKeepsActiveUnchanged() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        let firstId = manager.accounts[0].id
        manager.addAccount(startOAuth: false)
        let secondId = manager.accounts[1].id

        manager.activeAccountId = secondId
        manager.removeAccount(id: firstId)

        XCTAssertEqual(manager.activeAccountId, secondId)
    }

    // MARK: - Alias

    func testSetAliasUpdatesAccount() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        let id = manager.accounts[0].id

        manager.setAlias("Work", for: id)

        XCTAssertEqual(manager.accounts[0].alias, "Work")
    }

    func testSetEmptyAliasClearsAlias() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        let id = manager.accounts[0].id
        manager.setAlias("Work", for: id)

        manager.setAlias("", for: id)

        XCTAssertNil(manager.accounts[0].alias)
    }

    func testSetAliasIsPersisted() {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        let id = manager.accounts[0].id
        manager.setAlias("Personal 🏠", for: id)

        let manager2 = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        XCTAssertEqual(manager2.accounts[0].alias, "Personal 🏠")
    }

    // MARK: - Per-Account Keychain Isolation

    func testPerAccountKeychainIsolation() throws {
        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        manager.addAccount(startOAuth: false)
        manager.addAccount(startOAuth: false)

        let id1 = manager.accounts[0].id
        let id2 = manager.accounts[1].id
        XCTAssertNotEqual(id1, id2)

        // Each account gets its own Keychain entry (different account attribute)
        let store1 = StoredCredentialsStore(accountId: id1, directoryURL: directoryURL, keychainService: keychainService)
        let store2 = StoredCredentialsStore(accountId: id2, directoryURL: directoryURL, keychainService: keychainService)
        let cred1 = StoredCredentials(accessToken: "token-1", refreshToken: nil, expiresAt: nil, scopes: [])
        let cred2 = StoredCredentials(accessToken: "token-2", refreshToken: nil, expiresAt: nil, scopes: [])

        try store1.save(cred1)
        try store2.save(cred2)

        XCTAssertEqual(store1.load(defaultScopes: [])?.accessToken, "token-1")
        XCTAssertEqual(store2.load(defaultScopes: [])?.accessToken, "token-2")
    }

    // MARK: - Migration

    func testMigratesLegacySingleAccountOnFirstLaunch() throws {
        // Write old credentials.json (single-account format)
        let legacyCredentials = StoredCredentials(
            accessToken: "legacy-token",
            refreshToken: "legacy-refresh",
            expiresAt: nil,
            scopes: UsageService.defaultOAuthScopes
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(legacyCredentials)
        try data.write(
            to: directoryURL.appendingPathComponent("credentials.json"),
            options: .atomic
        )

        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)

        // Migration should have created one account
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertNotNil(manager.activeAccountId)

        // Old credentials.json should be gone (moved to per-account file by AccountManager migration)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("credentials.json").path
            )
        )

        let id = manager.accounts[0].id

        // Verify the token is readable through the store (migrates per-account file → Keychain on first load)
        let store = StoredCredentialsStore(accountId: id, directoryURL: directoryURL, keychainService: keychainService)
        let loaded = store.load(defaultScopes: UsageService.defaultOAuthScopes)
        XCTAssertEqual(loaded?.accessToken, "legacy-token")

        // Per-account file should be consumed by Keychain migration
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("credentials-\(id).json").path
            )
        )
    }

    func testMigratesLegacyHistoryFileOnFirstLaunch() throws {
        // Write a minimal legacy credentials.json so migration triggers
        let legacyCredentials = StoredCredentials(
            accessToken: "tok",
            refreshToken: nil,
            expiresAt: nil,
            scopes: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let credData = try encoder.encode(legacyCredentials)
        try credData.write(
            to: directoryURL.appendingPathComponent("credentials.json"),
            options: .atomic
        )

        // Write old history.json
        let legacyHistory = UsageHistory(dataPoints: [
            UsageDataPoint(pct5h: 0.5, pct7d: 0.3)
        ])
        let historyEncoder = JSONEncoder()
        historyEncoder.dateEncodingStrategy = .iso8601
        let histData = try historyEncoder.encode(legacyHistory)
        try histData.write(
            to: directoryURL.appendingPathComponent("history.json"),
            options: .atomic
        )

        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        let id = manager.accounts[0].id

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("history.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("history-\(id).json").path
            )
        )
    }

    func testMigrationDoesNotRunWhenAccountsFileExists() throws {
        // Create a valid accounts file first
        let entry = AccountEntry(id: "existing-id")
        let file = AccountsFile(accounts: [entry], activeAccountId: "existing-id")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(
            to: directoryURL.appendingPathComponent(AccountManager.accountsFileName),
            options: .atomic
        )

        // Also write an old credentials.json (should not be touched)
        try "should-not-migrate".write(
            to: directoryURL.appendingPathComponent("credentials.json"),
            atomically: true,
            encoding: .utf8
        )

        let manager = AccountManager(directoryURL: directoryURL, keychainService: keychainService)
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.accounts[0].id, "existing-id")
        // Legacy file should still be there (migration did not run)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("credentials.json").path
            )
        )
    }
}
