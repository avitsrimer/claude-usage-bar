import Foundation

/// Calendar pinned to Gregorian/`en_US` so `DateComponentsFormatter`'s `.abbreviated` unit
/// strings ("d", "h", "m") are deterministic regardless of the user's system locale or the
/// CI runner's locale. Without this, assertions on literal strings like "3h 50m" would be
/// environment-dependent and could drift silently.
let resetLabelCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}()

/// Restores the two-unit "Resets in Xh Ym" / "Resets in Xd Yh" formatting that commit
/// `a9ed221` removed in favor of `RelativeDateTimeFormatter`, which by design emits exactly
/// one unit (e.g. "in 3 hours" instead of "in 3h 50m").
///
/// - Non-future/past/zero `date` yields exactly `"Resetting…"`, never a negative duration.
/// - Zero-value units are dropped (`zeroFormattingBehavior = .dropAll`), so an exact hour
///   reads "Resets in 3h", not "Resets in 3h 0m".
///
/// Judgement call (day-scale precision): with `allowedUnits: [.day, .hour, .minute]`,
/// `maximumUnitCount = 2`, and `zeroFormattingBehavior = .dropAll`, a duration of 3 days + 0
/// hours + 50 minutes formats as **"3d 50m"** — dropping the zero-hour component lets the
/// formatter promote the next non-zero unit (minutes) into the freed second slot. The
/// original `a9ed221` code deliberately stopped at days+hours precision at the day scale
/// ("3d" only, no minutes, when hours == 0). This restoration intentionally keeps the
/// formatter's natural two-unit-cap behaviour ("3d 50m") instead of adding extra logic to
/// re-suppress minutes once a day is involved: "3d 50m" is strictly more informative than
/// "3d" and the formatter already computed it correctly, so throwing that precision away
/// would be a step backwards. See `ResetLabelFormatterTests` for the test asserting this.
func formatResetCountdown(from date: Date, now: Date, calendar: Calendar = resetLabelCalendar) -> String {
    guard date > now else { return "Resetting…" }

    let formatter = DateComponentsFormatter()
    formatter.calendar = calendar
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.maximumUnitCount = 2
    formatter.unitsStyle = .abbreviated
    formatter.zeroFormattingBehavior = .dropAll

    let interval = date.timeIntervalSince(now)
    guard let formatted = formatter.string(from: interval) else {
        return "Resetting…"
    }
    return "Resets in " + formatted
}
