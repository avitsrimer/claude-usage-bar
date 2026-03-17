import Foundation

struct AccountEntry: Codable, Identifiable, Equatable {
    let id: String
    var alias: String?
    var email: String?
    let createdAt: Date

    init(id: String = UUID().uuidString, alias: String? = nil, email: String? = nil) {
        self.id = id
        self.alias = alias
        self.email = email
        self.createdAt = Date()
    }

    func displayName(fallback: String? = nil) -> String {
        if let alias, !alias.isEmpty { return alias }
        let effective = fallback ?? email
        if let effective, !effective.isEmpty { return effective }
        return "Account"
    }
}

struct AccountsFile: Codable {
    var accounts: [AccountEntry]
    var activeAccountId: String?
}
