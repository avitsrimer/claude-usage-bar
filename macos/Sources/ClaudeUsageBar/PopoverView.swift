import SwiftUI

private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
}()

struct PopoverView: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var appUpdater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if accountManager.multiAccountEnabled && accountManager.accounts.count > 1 {
                AccountTabBar(accountManager: accountManager)
                Divider()
            }

            if let service = accountManager.activeService,
               let historyService = accountManager.activeHistoryService,
               let notificationService = accountManager.activeNotificationService {
                AccountContentView(
                    service: service,
                    historyService: historyService,
                    notificationService: notificationService,
                    appUpdater: appUpdater,
                    onRemove: {
                        if let id = accountManager.activeAccountId {
                            accountManager.removeAccount(id: id)
                        }
                    }
                )
            } else {
                noAccountView
            }
        }
        .frame(width: 340)
        .background(WindowPositionPreserver(trigger: accountManager.activeAccountId))
    }

    private var noAccountView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Usage")
                .font(.headline)
            Text("Add an account to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Add Account") {
                accountManager.addAccount()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            Divider()
            HStack {
                settingsButton
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var settingsButton: some View {
        SettingsLink { Text("Settings…") }
            .buttonStyle(.borderless)
            .font(.caption)
    }
}

// MARK: - Tab Bar

private struct AccountTabBar: View {
    @ObservedObject var accountManager: AccountManager

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Picker("", selection: Binding(
                    get: { accountManager.activeAccountId },
                    set: {
                        accountManager.activeAccountId = $0
                        accountManager.saveAccounts()
                    }
                )) {
                    ForEach(accountManager.accounts) { account in
                        Text(account.displayName()).tag(Optional(account.id))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Button {
                accountManager.addAccount()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Add Account")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Account Content

private struct AccountContentView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    let onRemove: () -> Void

    @State private var now = Date()
    @State private var minuteTimer: Timer?
    // Upstream #51's refresh-button cooldown. Kept in addition to UsageService.isFetching:
    // isFetching prevents overlapping network requests, this prevents the user from
    // hammering the button the instant a (possibly very fast, e.g. cached-error) fetch
    // completes. @State, so it's not unit-testable — see the plan.
    @State private var refreshCoolingDown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Claude Usage")
                .font(.headline)
            if service.isAwaitingCode {
                CodeEntryView(service: service)
            } else if !service.isAuthenticated {
                signInView
            } else {
                usageView
            }
        }
        .padding()
        .onAppear {
            now = Date()
            minuteTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                now = Date()
            }
        }
        .onDisappear {
            minuteTimer?.invalidate()
            minuteTimer = nil
        }
    }

    @ViewBuilder
    private var signInView: some View {
        Text("Sign in to view your usage.")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        Button("Sign in with Claude") {
            service.startOAuthFlow()
        }
        .buttonStyle(.borderedProminent)
        .frame(maxWidth: .infinity)

        if let error = service.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        }

        Divider()
        HStack {
            settingsButton
            Spacer()
            Button("Remove Account", action: onRemove)
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var usageView: some View {
        UsageBucketRow(
            label: "5-Hour Window",
            bucket: service.usage?.fiveHour,
            now: now
        )

        UsageBucketRow(
            label: "7-Day Window",
            bucket: service.usage?.sevenDay,
            now: now
        )

        if let opus = service.usage?.sevenDayOpus,
           opus.utilization != nil {
            Divider()
            Text("Per-Model (7 day)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            UsageBucketRow(label: "Opus", bucket: opus, now: now)
            if let sonnet = service.usage?.sevenDaySonnet {
                UsageBucketRow(label: "Sonnet", bucket: sonnet, now: now)
            }
        }

        if let extra = service.usage?.extraUsage, extra.isEnabled {
            Divider()
            ExtraUsageRow(extra: extra)
        }

        Divider()
        UsageChartView(historyService: historyService)

        if let error = service.lastError {
            Divider()
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
        }

        if let updaterError = appUpdater.lastError {
            Divider()
            Label(updaterError, systemImage: "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(.red)
                .font(.caption)
        }

        Divider()

        HStack(spacing: 12) {
            if let updated = service.lastUpdated {
                Text("Updated \(agoText(for: updated, now: now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        HStack(spacing: 12) {
            settingsButton
            Spacer()
            refreshControl
            if appUpdater.isConfigured {
                Button("Check for Updates…") {
                    appUpdater.checkForUpdates()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!appUpdater.canCheckForUpdates)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var settingsButton: some View {
        SettingsLink { Text("Settings…") }
            .buttonStyle(.borderless)
            .font(.caption)
    }

    // Fixed footprint (width + height) so swapping between the "Refresh" button and the
    // spinner never shifts the rest of the footer row. Same normalisation approach as
    // UsageBucketRow's blank placeholder for a missing reset date.
    private static let refreshControlSize = CGSize(width: 44, height: 14)
    private static let refreshCooldown: TimeInterval = 2 // upstream #51's value

    @ViewBuilder
    private var refreshControl: some View {
        if service.isFetching {
            ProgressView()
                .controlSize(.small)
                .frame(width: Self.refreshControlSize.width, height: Self.refreshControlSize.height)
        } else {
            Button("Refresh") { performRefresh() }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(refreshCoolingDown)
                .frame(width: Self.refreshControlSize.width, height: Self.refreshControlSize.height)
        }
    }

    private func performRefresh() {
        guard !refreshCoolingDown else { return }
        refreshCoolingDown = true
        Task { await service.fetchUsage() }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.refreshCooldown * 1_000_000_000))
            refreshCoolingDown = false
        }
    }

    private func agoText(for date: Date, now: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: now)
    }

}

// MARK: - Subviews

private struct CodeEntryView: View {
    @ObservedObject var service: UsageService
    @State private var code = ""

    var body: some View {
        Text("Paste the code from your browser:")
            .font(.subheadline)
            .foregroundStyle(.secondary)

        HStack(spacing: 4) {
            TextField("code#state", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { submit() }
            Button {
                if let str = NSPasteboard.general.string(forType: .string) {
                    code = str.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
        }

        HStack {
            Button("Cancel") {
                service.isAwaitingCode = false
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Submit") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(code.isEmpty)
        }
    }

    private func submit() {
        let value = code
        Task { await service.submitOAuthCode(value) }
    }
}

private struct UsageBucketRow: View {
    let label: String
    let bucket: UsageBucket?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(percentageText)
                    .font(.subheadline)
                    .monospacedDigit()
            }
            ProgressView(value: (bucket?.utilization ?? 0) / 100.0, total: 1.0)
                .tint(colorForPct((bucket?.utilization ?? 0) / 100.0))
            if let resetDate = bucket?.resetsAtDate {
                Text(resetText(for: resetDate, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(" ").font(.caption2)
            }
        }
    }

    private var percentageText: String {
        guard let pct = bucket?.utilization else { return "—" }
        return "\(Int(round(pct)))%"
    }

    private func resetText(for date: Date, now: Date) -> String {
        formatResetCountdown(from: date, now: now)
    }
}

private struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra Usage")
                .font(.subheadline)
            if let used = extra.usedCreditsAmount, let limit = extra.monthlyLimitAmount {
                HStack {
                    Text("\(ExtraUsage.formatUSD(used)) / \(ExtraUsage.formatUSD(limit))")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    if let pct = extra.utilization {
                        Text("\(Int(round(pct)))%")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
                ProgressView(value: (extra.utilization ?? 0) / 100.0, total: 1.0)
                    .tint(.blue)
            }
        }
    }
}

private func colorForPct(_ pct: Double) -> Color {
    switch pct {
    case ..<0.60: return .green
    case 0.60..<0.80: return .yellow
    default: return .red
    }
}

// MARK: - Window Position Preserver

/// Preserves the NSWindow origin when content changes size (e.g. account switching),
/// preventing MenuBarExtra from repositioning the window off-screen on full-screen spaces.
private struct WindowPositionPreserver: NSViewRepresentable {
    let trigger: String?

    class Coordinator {
        var savedOrigin: NSPoint?
        var lastTrigger: String? = "initial"
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        guard context.coordinator.lastTrigger != trigger else { return }

        context.coordinator.savedOrigin = window.frame.origin
        context.coordinator.lastTrigger = trigger

        DispatchQueue.main.async {
            if let origin = context.coordinator.savedOrigin {
                window.setFrameOrigin(origin)
            }
        }
    }
}
