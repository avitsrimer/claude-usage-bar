import Foundation
import Combine

@MainActor
class AccountManager: ObservableObject {
    @Published private(set) var accounts: [AccountEntry] = []
    @Published var activeAccountId: String?

    // Derived published state for the menu bar icon (reactive to active service changes)
    @Published private(set) var isActiveAccountAuthenticated = false
    @Published private(set) var activePct5h: Double = 0
    @Published private(set) var activePct7d: Double = 0

    private(set) var services: [String: UsageService] = [:]
    private(set) var historyServices: [String: UsageHistoryService] = [:]
    private(set) var notificationServices: [String: NotificationService] = [:]

    private var emailCancellables: [String: AnyCancellable] = [:]
    private var activeServiceCancellables = Set<AnyCancellable>()
    private var accountIdCancellable: AnyCancellable?

    let directoryURL: URL
    let keychainService: String
    static let accountsFileName = "accounts.json"

    var activeService: UsageService? { services[activeAccountId ?? ""] }
    var activeHistoryService: UsageHistoryService? { historyServices[activeAccountId ?? ""] }
    var activeNotificationService: NotificationService? { notificationServices[activeAccountId ?? ""] }

    init(
        directoryURL: URL = AppPaths.configDirectoryURL,
        keychainService: String = "claude-usage-bar"
    ) {
        self.directoryURL = directoryURL
        self.keychainService = keychainService
        migrateIfNeeded()
        loadAccounts()
        for account in accounts {
            services[account.id] = makeService(for: account)
        }
        if activeAccountId == nil {
            activeAccountId = accounts.first?.id
        }
        observeActiveAccountId()
    }

    // MARK: - Polling

    func startPolling() {
        for service in services.values {
            service.startPolling()
        }
    }

    // MARK: - Account Management

    func addAccount(startOAuth: Bool = true) {
        let entry = AccountEntry()
        accounts.append(entry)
        let service = makeService(for: entry)
        services[entry.id] = service
        activeAccountId = entry.id
        saveAccounts()
        if startOAuth {
            service.startOAuthFlow()
        }
    }

    func removeAccount(id: String) {
        services[id]?.signOut()
        services.removeValue(forKey: id)
        historyServices.removeValue(forKey: id)
        notificationServices.removeValue(forKey: id)
        emailCancellables.removeValue(forKey: id)
        accounts.removeAll { $0.id == id }
        if activeAccountId == id {
            activeAccountId = accounts.first?.id
        }
        saveAccounts()
    }

    func setAlias(_ alias: String, for id: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].alias = alias.isEmpty ? nil : alias
        if let service = services[id] {
            notificationServices[id]?.accountDisplayName = accounts[index].displayName(
                fallback: service.accountEmail
            )
        }
        saveAccounts()
    }

    // MARK: - Persistence

    func saveAccounts() {
        let file = AccountsFile(accounts: accounts, activeAccountId: activeAccountId)
        guard let data = try? Self.encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(
            to: directoryURL.appendingPathComponent(Self.accountsFileName),
            options: .atomic
        )
    }

    // MARK: - Private

    private func makeService(for entry: AccountEntry) -> UsageService {
        let history = UsageHistoryService(accountId: entry.id, directoryURL: directoryURL)
        history.loadHistory()
        historyServices[entry.id] = history

        let notification = NotificationService(accountId: entry.id)
        notificationServices[entry.id] = notification

        let store = StoredCredentialsStore(accountId: entry.id, directoryURL: directoryURL, keychainService: keychainService)
        let service = UsageService(credentialsStore: store)
        service.historyService = history
        service.notificationService = notification

        let cancellable = service.$accountEmail
            .compactMap { $0 }
            .sink { @MainActor [weak self] email in
                guard let self,
                      let index = self.accounts.firstIndex(where: { $0.id == entry.id }),
                      self.accounts[index].email != email else { return }
                self.accounts[index].email = email
                self.notificationServices[entry.id]?.accountDisplayName =
                    self.accounts[index].displayName(fallback: email)
                self.saveAccounts()
            }
        emailCancellables[entry.id] = cancellable

        return service
    }

    private func observeActiveAccountId() {
        accountIdCancellable = $activeAccountId
            .sink { @MainActor [weak self] newId in
                self?.updateActiveServiceObservers(for: newId)
            }
    }

    private func updateActiveServiceObservers(for accountId: String?) {
        activeServiceCancellables.removeAll()
        guard let service = services[accountId ?? ""] else {
            isActiveAccountAuthenticated = false
            activePct5h = 0
            activePct7d = 0
            return
        }
        service.$isAuthenticated
            .sink { @MainActor [weak self] value in self?.isActiveAccountAuthenticated = value }
            .store(in: &activeServiceCancellables)
        service.$usage
            .sink { @MainActor [weak self] _ in
                self?.activePct5h = service.pct5h
                self?.activePct7d = service.pct7d
            }
            .store(in: &activeServiceCancellables)
    }

    // MARK: - Migration (single-account → multi-account)

    private func migrateIfNeeded() {
        let accountsURL = directoryURL.appendingPathComponent(Self.accountsFileName)
        let legacyCredentialsURL = directoryURL.appendingPathComponent("credentials.json")
        let legacyHistoryURL = directoryURL.appendingPathComponent("history.json")

        guard !FileManager.default.fileExists(atPath: accountsURL.path),
              FileManager.default.fileExists(atPath: legacyCredentialsURL.path) else { return }

        let id = UUID().uuidString
        let newCredentialsURL = directoryURL.appendingPathComponent("credentials-\(id).json")
        let newHistoryURL = directoryURL.appendingPathComponent("history-\(id).json")

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: legacyCredentialsURL, to: newCredentialsURL)
        if FileManager.default.fileExists(atPath: legacyHistoryURL.path) {
            try? FileManager.default.moveItem(at: legacyHistoryURL, to: newHistoryURL)
        }

        let entry = AccountEntry(id: id)
        let file = AccountsFile(accounts: [entry], activeAccountId: id)
        guard let data = try? Self.encoder.encode(file) else { return }
        try? data.write(to: accountsURL, options: .atomic)
    }

    private func loadAccounts() {
        let url = directoryURL.appendingPathComponent(Self.accountsFileName)
        guard let data = try? Data(contentsOf: url),
              let file = try? Self.decoder.decode(AccountsFile.self, from: data) else { return }
        accounts = file.accounts
        activeAccountId = file.activeAccountId
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

