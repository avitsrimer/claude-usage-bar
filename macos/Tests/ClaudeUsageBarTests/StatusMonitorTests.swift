import XCTest
@testable import ClaudeUsageBar

/// Tests for the `@MainActor` `ObservableObject` `StatusMonitor`. Uses a virtual clock that
/// yields immediately so backoff progressions complete in milliseconds. Notifications go
/// through a private `NotificationCenter` to avoid coupling to `NSWorkspace`.
@MainActor
final class StatusMonitorTests: XCTestCase {

    func testRefreshPopulatesSnapshotOnSuccess() async throws {
        let summary = StatusPageSummary(
            components: [StatusComponent(id: "a", name: "claude.ai", status: .partialOutage)],
            incidents: []
        )
        let stub = StubHTTPClient(result: .success(summary))
        let client = StatusPageClient(http: stub)
        let monitor = StatusMonitor(
            client: client,
            filter: .default,
            clock: ImmediateClock(),
            notificationCenter: NotificationCenter()
        )
        await monitor.refresh()
        XCTAssertNotNil(monitor.snapshot)
        XCTAssertEqual(monitor.snapshot?.rollup, .partialOutage)
        XCTAssertNil(monitor.lastError)
    }

    func testRefreshSetsLastErrorOnFailureAndKeepsSnapshotNil() async throws {
        let stub = StubHTTPClient(result: .failure(.http(500)))
        let client = StatusPageClient(http: stub)
        let monitor = StatusMonitor(
            client: client,
            filter: .default,
            clock: ImmediateClock(),
            notificationCenter: NotificationCenter()
        )
        await monitor.refresh()
        XCTAssertNil(monitor.snapshot)
        XCTAssertEqual(monitor.lastError, .http(500))
    }

    func testBackoffDoublesOnFailureAndResetsOnSuccess() async throws {
        let stub = StubHTTPClient(result: .failure(.http(503)))
        let client = StatusPageClient(http: stub)
        let monitor = StatusMonitor(
            client: client,
            filter: .default,
            clock: ImmediateClock(),
            baseInterval: 60,
            maxBackoff: 600,
            notificationCenter: NotificationCenter()
        )
        // Initial value
        XCTAssertEqual(monitor.currentInterval, 60)
        await monitor.refresh()
        XCTAssertEqual(monitor.currentInterval, 120)
        await monitor.refresh()
        XCTAssertEqual(monitor.currentInterval, 240)

        // Now flip to success -> resets to baseInterval.
        let summary = StatusPageSummary(components: [], incidents: [])
        stub.result = .success(summary)
        await monitor.refresh()
        XCTAssertEqual(monitor.currentInterval, 60)
    }

    func testBackoffCapsAtMax() async throws {
        let stub = StubHTTPClient(result: .failure(.http(500)))
        let client = StatusPageClient(http: stub)
        let monitor = StatusMonitor(
            client: client,
            filter: .default,
            clock: ImmediateClock(),
            baseInterval: 60,
            maxBackoff: 200,
            notificationCenter: NotificationCenter()
        )
        for _ in 0..<10 {
            await monitor.refresh()
        }
        XCTAssertLessThanOrEqual(monitor.currentInterval, 200)
        XCTAssertEqual(monitor.currentInterval, 200)
    }

    func testStartStopIsIdempotent() {
        let stub = StubHTTPClient(result: .success(StatusPageSummary(components: [], incidents: [])))
        let client = StatusPageClient(http: stub)
        let monitor = StatusMonitor(
            client: client,
            clock: ImmediateClock(),
            notificationCenter: NotificationCenter()
        )
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
        monitor.start() // second call no-op
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.stop() // double stop is safe
        XCTAssertFalse(monitor.isRunning)
    }

    func testSleepWakeNotificationsTogglePauseFlag() async throws {
        let center = NotificationCenter()
        let sleepName = Notification.Name("TestStatusMonitor.sleep")
        let wakeName = Notification.Name("TestStatusMonitor.wake")

        let stub = StubHTTPClient(result: .success(StatusPageSummary(components: [], incidents: [])))
        let client = StatusPageClient(http: stub)
        let monitor = StatusMonitor(
            client: client,
            clock: ImmediateClock(),
            notificationCenter: center,
            sleepNotification: sleepName,
            wakeNotification: wakeName
        )
        monitor.start()
        XCTAssertFalse(monitor.isPaused)

        center.post(name: sleepName, object: nil)
        // Allow the Task { @MainActor } continuation to flip the flag.
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(monitor.isPaused)

        center.post(name: wakeName, object: nil)
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(monitor.isPaused)

        monitor.stop()
    }

    func testRefreshWorksWhilePaused() async throws {
        let center = NotificationCenter()
        let sleepName = Notification.Name("TestStatusMonitor.sleep2")
        let wakeName = Notification.Name("TestStatusMonitor.wake2")
        let summary = StatusPageSummary(
            components: [StatusComponent(id: "a", name: "claude.ai", status: .operational)],
            incidents: []
        )
        let stub = StubHTTPClient(result: .success(summary))
        let client = StatusPageClient(http: stub)
        let monitor = StatusMonitor(
            client: client,
            clock: ImmediateClock(),
            notificationCenter: center,
            sleepNotification: sleepName,
            wakeNotification: wakeName
        )
        monitor.start()
        center.post(name: sleepName, object: nil)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(monitor.isPaused)

        // Refresh bypasses isPaused.
        await monitor.refresh()
        XCTAssertNotNil(monitor.snapshot)

        monitor.stop()
    }

    func testUpdateFilterRefreshesWhenRunning() async throws {
        let stub = StubHTTPClient(result: .success(StatusPageSummary(
            components: [StatusComponent(id: "a", name: "Only Match", status: .majorOutage)],
            incidents: []
        )))
        let client = StatusPageClient(http: stub)
        let monitor = StatusMonitor(
            client: client,
            filter: StatusComponentFilter(substrings: ["No Match"]),
            clock: ImmediateClock(),
            notificationCenter: NotificationCenter()
        )
        monitor.start()
        await monitor.refresh()
        XCTAssertEqual(monitor.snapshot?.allMonitoredComponents.count, 0)

        monitor.updateFilter(StatusComponentFilter(substrings: ["Only Match"]))
        // updateFilter fires an async Task { await self.refresh() } — give it a couple of yields.
        await Task.yield()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(monitor.snapshot?.allMonitoredComponents.count, 1)

        monitor.stop()
    }
}

// MARK: - Doubles

/// Mutable stub that returns the same canned result for every call until reassigned.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    enum Outcome { case success(StatusPageSummary); case failure(StatusError) }

    var result: Outcome

    init(result: Outcome) { self.result = result }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        switch result {
        case .success(let summary):
            // Encode the domain summary back into the wire shape the client expects.
            let dto = makeWireBody(from: summary)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (dto, response)
        case .failure(let err):
            throw err
        }
    }

    private func makeWireBody(from summary: StatusPageSummary) -> Data {
        // Build the wire-format JSON with snake_case keys.
        let components = summary.components.map { c -> [String: Any] in
            return [
                "id": c.id,
                "name": c.name,
                "status": c.status.rawValue
            ]
        }
        let incidents = summary.incidents.map { i -> [String: Any] in
            return [
                "id": i.id,
                "name": i.name,
                "status": i.status,
                "impact": i.impact
            ]
        }
        let body: [String: Any] = [
            "page": ["id": "p", "name": "Claude"],
            "components": components,
            "incidents": incidents,
            "scheduled_maintenances": [],
            "status": ["indicator": "none", "description": "ok"]
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }
}

/// Fast clock that returns immediately for every sleep — keeps poll-loop tests deterministic.
struct ImmediateClock: StatusClock {
    func now() -> Date { Date(timeIntervalSince1970: 0) }
    func sleep(for interval: TimeInterval) async throws {
        // Yield once to let the Task suspend; never wait wall-clock time.
        await Task.yield()
    }
}
