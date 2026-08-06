import Foundation

func pollingOptionLabel(
    for minutes: Int,
    locale: Locale = .autoupdatingCurrent
) -> String {
    localizedPollingInterval(for: minutes, locale: locale)
}

func localizedPollingInterval(for minutes: Int, locale: Locale) -> String {
    let measurement: Measurement<UnitDuration>
    if minutes < 60 {
        measurement = Measurement(value: Double(minutes), unit: .minutes)
    } else {
        measurement = Measurement(value: Double(minutes) / 60.0, unit: .hours)
    }

    return measurement.formatted(
        .measurement(
            width: .narrow,
            usage: .asProvided,
            numberFormatStyle: .number.precision(.fractionLength(0)).locale(locale)
        )
    )
}
