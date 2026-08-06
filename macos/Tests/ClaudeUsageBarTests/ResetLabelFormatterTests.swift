import XCTest
@testable import ClaudeUsageBar

final class ResetLabelFormatterTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 0)

    private func date(after seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    // MARK: - Core two-unit formatting (the a9ed221 spec)

    func testHoursAndMinutes() {
        // 3h 50m
        let target = date(after: 3 * 3600 + 50 * 60)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 3h 50m"
        )
    }

    func testDaysAndHours() {
        // 6d 17h
        let target = date(after: 6 * 86400 + 17 * 3600)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 6d 17h"
        )
    }

    func testSubHourMinutesOnly() {
        // 50m, no hours component
        let target = date(after: 50 * 60)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 50m"
        )
    }

    func testExactHourDropsZeroMinutes() {
        // Exactly 3 hours away must read "3h", never "3h 0m".
        let target = date(after: 3 * 3600)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 3h"
        )
    }

    // MARK: - Day-scale judgement call

    func testDayScaleWithZeroHoursPromotesMinutesIntoSecondSlot() {
        // 3 days + 0 hours + 50 minutes. Judgement call (documented in ResetLabelFormatter.swift
        // and the PR description): the zero-hour component is dropped, so the formatter's
        // maximumUnitCount = 2 cap is filled by promoting the next non-zero unit (minutes),
        // producing "3d 50m" rather than the original a9ed221 behaviour of "3d" only.
        let target = date(after: 3 * 86400 + 50 * 60)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 3d 50m"
        )
    }

    func testDayScaleWithNonZeroHoursCapsAtTwoUnits() {
        // 3 days + 4 hours, no minutes: capped at two units (days + hours) since hours is
        // already non-zero, so there's no third slot to fill with minutes.
        let target = date(after: 3 * 86400 + 4 * 3600)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resets in 3d 4h"
        )
    }

    // MARK: - Non-future dates

    func testPastDateYieldsResetting() {
        let target = date(after: -60)
        XCTAssertEqual(
            formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar),
            "Resetting…"
        )
    }

    func testZeroDateYieldsResetting() {
        XCTAssertEqual(
            formatResetCountdown(from: now, now: now, calendar: resetLabelCalendar),
            "Resetting…"
        )
    }

    func testFarPastDateYieldsResettingNotNegativeDuration() {
        let target = date(after: -3 * 3600 - 50 * 60)
        let result = formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar)
        XCTAssertEqual(result, "Resetting…")
        XCTAssertFalse(result.contains("-"))
    }

    // MARK: - Sub-minute remainder (defensive edge case)

    func testSubMinuteRemainderRoundsToZeroMinutesRatherThanEmptyLabel() {
        // A future date less than a minute away rounds down to "0m" rather than dropping the
        // component to an empty string ("Resets in "). Still future, so this must not read
        // "Resetting…" — that's reserved for non-future dates.
        let target = date(after: 30)
        let result = formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar)
        XCTAssertEqual(result, "Resets in 0m")
    }

    // MARK: - Locale pinning

    func testCalendarLocaleIsPinnedRegardlessOfSystemLocale() {
        // Using the pinned resetLabelCalendar default should be equivalent to explicitly
        // passing it, independent of whatever locale the test runner's environment has.
        let target = date(after: 3 * 3600 + 50 * 60)
        let viaDefault = formatResetCountdown(from: target, now: now)
        let viaExplicitPin = formatResetCountdown(from: target, now: now, calendar: resetLabelCalendar)
        XCTAssertEqual(viaDefault, viaExplicitPin)
        XCTAssertEqual(viaDefault, "Resets in 3h 50m")
    }
}
