import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Time abstraction so `StatusMonitor`'s poll loop can be driven by a virtual clock in tests.
protocol StatusClock: Sendable {
    func now() -> Date
    func sleep(for interval: TimeInterval) async throws
}

struct SystemStatusClock: StatusClock {
    func now() -> Date { Date() }
    func sleep(for interval: TimeInterval) async throws {
        let nanos = UInt64(max(0, interval) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

/// `@MainActor` `ObservableObject` polling service for `status.claude.com`. Matches the
/// reactive convention used everywhere else in this app (`AccountManager`, `UsageService`,
/// `UsageHistoryService`, `NotificationService` are all `ObservableObject` + `@Published` —
/// see CLAUDE.md). Upstream declared this `@Observable` with `nonisolated(unsafe)` observer
/// tokens, which need Swift 5.9/5.10 respectively; converted here to avoid relying on
/// toolchain features newer than our CI's macos-14 Swift.
///
/// One instance for the whole app: status is account-independent, so `ClaudeUsageBarApp`
/// owns a single `StatusMonitor` and passes it down — it is not recreated per view and not
/// duplicated per account.
///
/// Lifecycle: `start()` is idempotent. `stop()` cancels the in-flight task. Sleep/wake events
/// from `NSWorkspace.shared.notificationCenter` flip `isPaused`; `refresh()` always runs.
@MainActor
final class StatusMonitor: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot?
    @Published private(set) var lastError: StatusError?
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var currentInterval: TimeInterval

    /// Plain interval constant standing in for upstream's `AppearanceSettings`-backed
    /// `StatusPollOptions` (that file is rejected by this fork). Not user-configurable —
    /// see the Task 7 PR description for the reasoning.
    nonisolated static let defaultPollInterval: TimeInterval = 5 * 60

    private let client: StatusPageClient
    private var filter: StatusComponentFilter
    private let clock: any StatusClock
    private var baseInterval: TimeInterval
    private let maxBackoff: TimeInterval
    private let notificationCenter: NotificationCenter

    private var pollTask: Task<Void, Never>?
    // Only MainActor-isolated methods mutate these; deinit reads them during teardown when
    // no concurrent access to the object is possible (matches UsageHistoryService's
    // terminationObserver pattern elsewhere in this app — no nonisolated(unsafe) needed).
    private var sleepObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?

    /// Notification names — defaulting to `NSWorkspace.willSleepNotification` / `didWakeNotification`
    /// when AppKit is available; falling back to private names so tests can post via an injected center.
    private let sleepNotification: Notification.Name
    private let wakeNotification: Notification.Name

    init(
        client: StatusPageClient,
        filter: StatusComponentFilter = .default,
        clock: any StatusClock = SystemStatusClock(),
        baseInterval: TimeInterval = StatusMonitor.defaultPollInterval,
        maxBackoff: TimeInterval = 30 * 60,
        notificationCenter: NotificationCenter? = nil,
        sleepNotification: Notification.Name? = nil,
        wakeNotification: Notification.Name? = nil
    ) {
        self.client = client
        self.filter = filter
        self.clock = clock
        self.baseInterval = baseInterval
        self.maxBackoff = maxBackoff
        self.currentInterval = baseInterval
        #if canImport(AppKit)
        self.notificationCenter = notificationCenter ?? NSWorkspace.shared.notificationCenter
        self.sleepNotification = sleepNotification ?? NSWorkspace.willSleepNotification
        self.wakeNotification = wakeNotification ?? NSWorkspace.didWakeNotification
        #else
        self.notificationCenter = notificationCenter ?? NotificationCenter.default
        self.sleepNotification = sleepNotification ?? Notification.Name("StatusMonitor.willSleep")
        self.wakeNotification = wakeNotification ?? Notification.Name("StatusMonitor.didWake")
        #endif
    }

    deinit {
        // Remove sleep/wake observers defensively. NotificationCenter.removeObserver(_:) is
        // thread-safe and requires no actor hop. The poll task holds weak self and will exit
        // on its own; observer tokens still need explicit removal to avoid dangling
        // registrations in the injected NotificationCenter.
        if let sleepObserver { notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        currentInterval = baseInterval
        installSleepWakeObservers()
        pollTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        if let sleepObserver {
            notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        isPaused = false
    }

    /// Manual one-shot fetch. Bypasses `isPaused` so a "Retry" affordance always works.
    func refresh() async {
        await fetchOnce()
    }

    func updateFilter(_ filter: StatusComponentFilter) {
        self.filter = filter
        if isRunning {
            Task { await self.refresh() }
        }
    }

    // MARK: - Loop

    private func runLoop() async {
        while isRunning, !Task.isCancelled {
            // Honour pause: if paused, wait until resumed (or stop()).
            while isPaused, isRunning, !Task.isCancelled {
                // Sleep in 1-second chunks; the wake notification flips isPaused back to false.
                do {
                    try await clock.sleep(for: 1)
                } catch {
                    return
                }
            }
            if !isRunning || Task.isCancelled { return }

            await fetchOnce()

            do {
                try await clock.sleep(for: currentInterval)
            } catch {
                return
            }
        }
    }

    private func fetchOnce() async {
        do {
            let summary = try await client.fetchSummary()
            let snap = StatusSnapshot.make(from: summary, filter: filter, now: clock.now())
            self.snapshot = snap
            self.lastError = nil
            // Reset the backoff on any success.
            self.currentInterval = baseInterval
        } catch let error as StatusError {
            self.lastError = error
            // Exponential backoff doubles, capped at maxBackoff.
            self.currentInterval = min(currentInterval * 2, maxBackoff)
        } catch {
            self.lastError = .transport(.unknown)
            self.currentInterval = min(currentInterval * 2, maxBackoff)
        }
    }

    // MARK: - Sleep / Wake

    private func installSleepWakeObservers() {
        // Remove any prior observer (idempotent).
        if let sleepObserver { notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }

        sleepObserver = notificationCenter.addObserver(
            forName: sleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The closure runs on .main; hop to the actor to mutate state safely.
            Task { @MainActor [weak self] in
                self?.isPaused = true
            }
        }
        wakeObserver = notificationCenter.addObserver(
            forName: wakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPaused = false
            }
        }
    }
}
