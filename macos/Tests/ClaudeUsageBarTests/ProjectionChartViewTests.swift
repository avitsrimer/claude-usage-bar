import XCTest
import SwiftUI
@testable import ClaudeUsageBar

/// Unit tests for `ProjectionChartView.geometry(projection:reset:)` — the pure clamping/
/// branching logic that decides the chart's rendered endpoint, color, and run-out line.
/// Constructed directly from a `UsageProjection` value, no `View` or `Chart` involved.
final class ProjectionChartViewTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testRunsOutEndsAt100PercentAtCrossingDateWithRedColor() throws {
        let reset = base.addingTimeInterval(3600)
        let crossing = base.addingTimeInterval(900)
        let projection = UsageProjection(
            outcome: .runsOut(at: crossing),
            ratePerSecond: 0.0005,
            currentPct: 0.3,
            now: base,
            reset: reset
        )

        let geo = ProjectionChartView.geometry(projection: projection, reset: reset)

        XCTAssertEqual(geo.points.count, 2)
        let first = try XCTUnwrap(geo.points.first)
        let last = try XCTUnwrap(geo.points.last)
        XCTAssertEqual(first.date, base)
        XCTAssertEqual(first.pct, 30, accuracy: 0.0001)
        XCTAssertEqual(last.date, crossing)
        XCTAssertEqual(last.pct, 100, accuracy: 0.0001)
        XCTAssertEqual(geo.runsOutDate, crossing)
        XCTAssertEqual(geo.color, .red)
        XCTAssertEqual(geo.now, base)
        XCTAssertEqual(geo.startPct, 30, accuracy: 0.0001)
    }

    func testLastsUntilResetEndsAtResetWithProjectedPercentAndGreenColor() throws {
        let reset = base.addingTimeInterval(3600)
        let projection = UsageProjection(
            outcome: .lastsUntilReset,
            ratePerSecond: 0.0001, // rising slowly enough that it still lasts until reset
            currentPct: 0.2,
            now: base,
            reset: reset
        )

        let geo = ProjectionChartView.geometry(projection: projection, reset: reset)
        let last = try XCTUnwrap(geo.points.last)

        XCTAssertNil(geo.runsOutDate)
        XCTAssertEqual(geo.color, .green)
        XCTAssertEqual(last.date, reset)
        // 0.2 + 0.0001 * 3600 = 0.56 -> 56%
        XCTAssertEqual(last.pct, 56, accuracy: 0.01)
    }

    func testLastsUntilResetClampsProjectedPercentAboveHundred() throws {
        let reset = base.addingTimeInterval(3600)
        let projection = UsageProjection(
            outcome: .lastsUntilReset,
            ratePerSecond: 1.0, // absurdly high rate — projected value would blow past 100%
            currentPct: 0.5,
            now: base,
            reset: reset
        )

        let geo = ProjectionChartView.geometry(projection: projection, reset: reset)
        let last = try XCTUnwrap(geo.points.last)

        XCTAssertEqual(last.pct, 100, accuracy: 0.0001)
        XCTAssertEqual(geo.color, .green, "no run-out date, so still green even when clamped to 100")
    }

    func testLastsUntilResetClampsProjectedPercentBelowZero() throws {
        let reset = base.addingTimeInterval(3600)
        let projection = UsageProjection(
            outcome: .lastsUntilReset,
            ratePerSecond: -1.0, // declining sharply — projected value would go negative
            currentPct: 0.1,
            now: base,
            reset: reset
        )

        let geo = ProjectionChartView.geometry(projection: projection, reset: reset)
        let last = try XCTUnwrap(geo.points.last)

        XCTAssertEqual(last.pct, 0, accuracy: 0.0001)
    }
}
