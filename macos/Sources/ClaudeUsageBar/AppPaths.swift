import Foundation

enum AppPaths {
    static var configDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claude-usage-bar", isDirectory: true)
    }
}
