import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var accountManager = AccountManager()
    @StateObject private var appUpdater = AppUpdater()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(accountManager: accountManager, appUpdater: appUpdater)
        } label: {
            Image(nsImage: accountManager.isActiveAccountAuthenticated
                ? renderIcon(pct5h: accountManager.activePct5h, pct7d: accountManager.activePct7d)
                : renderUnauthenticatedIcon()
            )
            .task {
                accountManager.startPolling()
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowContent(accountManager: accountManager)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
    }
}
