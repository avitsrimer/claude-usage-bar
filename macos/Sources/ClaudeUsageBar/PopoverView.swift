import SwiftUI

struct PopoverView: View {
    @ObservedObject var accountManager: AccountManager
    @ObservedObject var appUpdater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountTabBar(accountManager: accountManager)
            Divider()

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
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(accountManager.accounts) { account in
                        AccountTab(
                            account: account,
                            isActive: accountManager.activeAccountId == account.id,
                            onSelect: {
                                accountManager.activeAccountId = account.id
                                accountManager.saveAccounts()
                            },
                            onRename: { alias in
                                accountManager.setAlias(alias, for: account.id)
                            }
                        )
                    }
                }
            }

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            Button {
                accountManager.addAccount()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Add Account")
            .padding(.trailing, 4)
        }
        .frame(height: 28)
    }
}

private struct AccountTab: View {
    let account: AccountEntry
    let isActive: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void

    @State private var isHovered = false
    @State private var isEditing = false

    var body: some View {
        Button(action: onSelect) {
            Text(account.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 28)
        }
        .buttonStyle(.borderless)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button {
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 7, weight: .medium))
                        .padding(3)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                        .clipShape(Circle())
                }
                .buttonStyle(.borderless)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { isHovered = $0 }
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            AliasEditPopover(
                currentAlias: account.alias ?? "",
                placeholder: account.email ?? "e.g. Work, Personal, 🏢",
                onSave: { alias in
                    onRename(alias)
                    isEditing = false
                },
                onCancel: { isEditing = false }
            )
        }
    }
}

private struct AliasEditPopover: View {
    @State private var text: String
    let placeholder: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(
        currentAlias: String,
        placeholder: String,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _text = State(initialValue: currentAlias)
        self.placeholder = placeholder
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename Account")
                .font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { onSave(text) }
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.borderless)
                Spacer()
                Button("Save") { onSave(text) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

// MARK: - Account Content

private struct AccountContentView: View {
    @ObservedObject var service: UsageService
    @ObservedObject var historyService: UsageHistoryService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var appUpdater: AppUpdater
    let onRemove: () -> Void

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
            bucket: service.usage?.fiveHour
        )

        UsageBucketRow(
            label: "7-Day Window",
            bucket: service.usage?.sevenDay
        )

        if let opus = service.usage?.sevenDayOpus,
           opus.utilization != nil {
            Divider()
            Text("Per-Model (7 day)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            UsageBucketRow(label: "Opus", bucket: opus)
            if let sonnet = service.usage?.sevenDaySonnet {
                UsageBucketRow(label: "Sonnet", bucket: sonnet)
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
                Text("Updated \(updated, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        HStack(spacing: 12) {
            settingsButton
            Spacer()
            Button("Refresh") {
                Task { await service.fetchUsage() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
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
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var percentageText: String {
        guard let pct = bucket?.utilization else { return "—" }
        return "\(Int(round(pct)))%"
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
