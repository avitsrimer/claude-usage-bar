import XCTest
@testable import ClaudeUsageBar

@MainActor
final class UsageHistoryServiceTests: XCTestCase {
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

    private func historyFileURL(accountId: String = "acct-1") -> URL {
        directoryURL.appendingPathComponent("history-\(accountId).json")
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue
    }

    // MARK: - Immediate persistence

    func testRecordDataPointPersistsImmediately() throws {
        let service = UsageHistoryService(accountId: "acct-1", directoryURL: directoryURL)

        service.recordDataPoint(pct5h: 12, pct7d: 34)

        let url = historyFileURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder.claudeUsageBarTestHistoryDecoder.decode(UsageHistory.self, from: data)
        XCTAssertEqual(decoded.dataPoints.count, 1)
        XCTAssertEqual(decoded.dataPoints[0].pct5h, 12)
        XCTAssertEqual(decoded.dataPoints[0].pct7d, 34)
    }

    // MARK: - Permissions

    func testFreshFileIsCreatedWithMode0600() throws {
        let service = UsageHistoryService(accountId: "acct-1", directoryURL: directoryURL)

        service.recordDataPoint(pct5h: 1, pct7d: 2)

        let permissions = try posixPermissions(at: historyFileURL())
        XCTAssertEqual(permissions, 0o600)
    }

    func testPreExisting0644FileEndsUpAt0600AfterFlush() throws {
        let url = historyFileURL()
        let existing = UsageHistory(dataPoints: [UsageDataPoint(pct5h: 5, pct7d: 6)])
        let data = try JSONEncoder.claudeUsageBarTestHistoryEncoder.encode(existing)
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o644])

        let permissionsBefore = try posixPermissions(at: url)
        XCTAssertEqual(permissionsBefore, 0o644)

        let service = UsageHistoryService(accountId: "acct-1", directoryURL: directoryURL)
        service.loadHistory()
        service.recordDataPoint(pct5h: 7, pct7d: 8)

        let permissionsAfter = try posixPermissions(at: url)
        XCTAssertEqual(permissionsAfter, 0o600)
    }

    // MARK: - Retention pruning

    func testRetentionPruningAppliesOnWrite() throws {
        let service = UsageHistoryService(accountId: "acct-1", directoryURL: directoryURL)

        let old = UsageDataPoint(timestamp: Date().addingTimeInterval(-31 * 86400), pct5h: 1, pct7d: 1)
        let recent = UsageDataPoint(timestamp: Date(), pct5h: 2, pct7d: 2)
        service.history.dataPoints = [old, recent]

        service.flushToDisk()

        let data = try Data(contentsOf: historyFileURL())
        let decoded = try JSONDecoder.claudeUsageBarTestHistoryDecoder.decode(UsageHistory.self, from: data)
        XCTAssertEqual(decoded.dataPoints.count, 1)
        XCTAssertEqual(decoded.dataPoints[0].pct5h, 2)
    }

    // MARK: - Flush failure paths

    /// `createFile` fails when the containing directory has no write permission. `flushToDisk`
    /// must not crash and must leave no history file behind (the `guard created else { return }`
    /// branch, which never reaches `replaceItemAt`).
    func testFlushToDiskDoesNotCrashWhenDirectoryIsNotWritable() throws {
        let service = UsageHistoryService(accountId: "acct-1", directoryURL: directoryURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directoryURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        }

        service.recordDataPoint(pct5h: 1, pct7d: 2)

        XCTAssertFalse(FileManager.default.fileExists(atPath: historyFileURL().path))
        let leftover = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftover.isEmpty, "createFile failing must not leave an orphaned temp file")
    }

    /// `replaceItemAt` fails when the destination is immutable (`chflags uchg`), even though
    /// the containing directory (and therefore `createFile` for the temp file) is writable.
    /// The `catch` block must remove the orphaned temp file and leave the immutable file
    /// untouched, without crashing.
    func testFlushToDiskCleansUpTempFileWhenReplaceItemFails() throws {
        let url = historyFileURL()
        let service = UsageHistoryService(accountId: "acct-1", directoryURL: directoryURL)
        service.recordDataPoint(pct5h: 1, pct7d: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        }

        let before = try Data(contentsOf: url)

        service.recordDataPoint(pct5h: 3, pct7d: 4)

        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after, "the immutable destination must be left untouched on replaceItemAt failure")

        let leftover = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftover.isEmpty, "temp file must be removed when replaceItemAt fails")
    }

    // MARK: - Corrupt file recovery

    func testCorruptFileMovesToBakAndHistoryResets() throws {
        let url = historyFileURL()
        try Data("not valid json".utf8).write(to: url)

        let backupURL = directoryURL.appendingPathComponent("history-acct-1.bak.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))

        let service = UsageHistoryService(accountId: "acct-1", directoryURL: directoryURL)
        service.loadHistory()

        XCTAssertTrue(service.history.dataPoints.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Test-local coding helpers
// UsageHistoryService's JSONEncoder/Decoder extensions are file-private, so tests
// use their own equivalents rather than un-privating production code for testability.

private extension JSONDecoder {
    static let claudeUsageBarTestHistoryDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let claudeUsageBarTestHistoryEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
