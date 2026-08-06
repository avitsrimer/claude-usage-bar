import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @StateObject private var accountManager = AccountManager()
    @StateObject private var appUpdater = AppUpdater()
    // Account-independent — one instance for the whole app, owned here and passed down to
    // the views that need it. Not created per-account (AccountManager) or per-view
    // (PopoverView), since status.claude.com has nothing to do with any single account.
    @StateObject private var statusMonitor = StatusMonitor(client: StatusPageClient())

    var body: some Scene {
        MenuBarExtra {
            PopoverView(accountManager: accountManager, appUpdater: appUpdater, statusMonitor: statusMonitor)
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
