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

    var displayName: String {
        if let alias, !alias.isEmpty { return alias }
        if let email, !email.isEmpty { return email }
        return "Account"
    }
}

struct AccountsFile: Codable {
    var accounts: [AccountEntry]
    var activeAccountId: String?
}
