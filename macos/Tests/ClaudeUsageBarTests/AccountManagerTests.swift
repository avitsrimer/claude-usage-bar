import XCTest
@testable import ClaudeUsageBar

final class AccountEntryTests: XCTestCase {
    func testDisplayNamePrefersAlias() {
        let entry = AccountEntry(alias: "Work", email: "work@example.com")
        XCTAssertEqual(entry.displayName, "Work")
    }

    func testDisplayNameFallsBackToEmail() {
        let entry = AccountEntry(alias: nil, email: "me@example.com")
        XCTAssertEqual(entry.displayName, "me@example.com")
    }

    func testDisplayNameFallsBackToAccountWhenEmpty() {
        let entry = AccountEntry(alias: nil, email: nil)
        XCTAssertEqual(entry.displayName, "Account")
    }

    func testDisplayNameIgnoresEmptyAlias() {
        let entry = AccountEntry(alias: "", email: "me@example.com")
        XCTAssertEqual(entry.displayName, "me@example.com")
    }

    func testDisplayNameEmojiAlias() {
        let entry = AccountEntry(alias: "🏢", email: "work@example.com")
        XCTAssertEqual(entry.displayName, "🏢")
    }
}

@MainActor
final class AccountManagerTests: XCTestCase {
    private var directoryURL: URL!

    override func setUp() {
        super.setUp()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directoryURL)
        super.tearDown()
    }

    // MARK: - Initial State

    func testStartsEmptyWhenNoAccountsFile() {
        let manager = AccountManager(directoryURL: directoryURL)
        XCTAssertTrue(manager.accounts.isEmpty)
        XCTAssertNil(manager.activeAccountId)
    }

    func testLoadsPersistedAccounts() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        let id = manager.accounts[0].id

        let manager2 = AccountManager(directoryURL: directoryURL)
        XCTAssertEqual(manager2.accounts.count, 1)
        XCTAssertEqual(manager2.accounts[0].id, id)
        XCTAssertEqual(manager2.activeAccountId, id)
    }

    // MARK: - Add / Remove

    func testAddAccountCreatesEntry() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertNotNil(manager.activeAccountId)
        XCTAssertEqual(manager.activeAccountId, manager.accounts[0].id)
    }

    func testAddMultipleAccountsSwitchesActiveToNewest() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        let firstId = manager.accounts[0].id
        manager.addAccount()
        XCTAssertEqual(manager.accounts.count, 2)
        XCTAssertNotEqual(manager.activeAccountId, firstId)
    }

    func testRemoveAccountDeletesEntry() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        let id = manager.accounts[0].id
        manager.removeAccount(id: id)
        XCTAssertTrue(manager.accounts.isEmpty)
        XCTAssertNil(manager.activeAccountId)
    }

    func testRemoveActiveAccountSwitchesToFirstRemaining() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        let firstId = manager.accounts[0].id
        manager.addAccount()
        let secondId = manager.accounts[1].id

        manager.activeAccountId = secondId
        manager.removeAccount(id: secondId)

        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertEqual(manager.activeAccountId, firstId)
    }

    func testRemoveNonActiveAccountKeepsActiveUnchanged() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        let firstId = manager.accounts[0].id
        manager.addAccount()
        let secondId = manager.accounts[1].id

        manager.activeAccountId = secondId
        manager.removeAccount(id: firstId)

        XCTAssertEqual(manager.activeAccountId, secondId)
    }

    // MARK: - Alias

    func testSetAliasUpdatesAccount() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        let id = manager.accounts[0].id

        manager.setAlias("Work", for: id)

        XCTAssertEqual(manager.accounts[0].alias, "Work")
    }

    func testSetEmptyAliasClearsAlias() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        let id = manager.accounts[0].id
        manager.setAlias("Work", for: id)

        manager.setAlias("", for: id)

        XCTAssertNil(manager.accounts[0].alias)
    }

    func testSetAliasIsPersisted() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        let id = manager.accounts[0].id
        manager.setAlias("Personal 🏠", for: id)

        let manager2 = AccountManager(directoryURL: directoryURL)
        XCTAssertEqual(manager2.accounts[0].alias, "Personal 🏠")
    }

    // MARK: - Per-Account Files

    func testPerAccountCredentialFiles() {
        let manager = AccountManager(directoryURL: directoryURL)
        manager.addAccount()
        manager.addAccount()

        let id1 = manager.accounts[0].id
        let id2 = manager.accounts[1].id

        let file1 = directoryURL.appendingPathComponent("credentials-\(id1).json").path
        let file2 = directoryURL.appendingPathComponent("credentials-\(id2).json").path
        XCTAssertNotEqual(file1, file2)
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

        let manager = AccountManager(directoryURL: directoryURL)

        // Migration should have created one account
        XCTAssertEqual(manager.accounts.count, 1)
        XCTAssertNotNil(manager.activeAccountId)

        // Old credentials.json should be gone; new per-account file should exist
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directoryURL.appendingPathComponent("credentials.json").path
            )
        )

        let id = manager.accounts[0].id
        let newCredentialsURL = directoryURL.appendingPathComponent("credentials-\(id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newCredentialsURL.path))

        // Verify the token is readable through the store
        let store = StoredCredentialsStore(accountId: id, directoryURL: directoryURL)
        let loaded = store.load(defaultScopes: UsageService.defaultOAuthScopes)
        XCTAssertEqual(loaded?.accessToken, "legacy-token")
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

        let manager = AccountManager(directoryURL: directoryURL)
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

        let manager = AccountManager(directoryURL: directoryURL)
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
