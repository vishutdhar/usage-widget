import Foundation

/// Measurement times as the widget writes them, in the locale, time zone
/// and calendar the caller passes (the SwiftUI environment's, in a view).
public enum TimeText {
    /// The locale's short time ("10:04 AM") on the same day as `now`,
    /// otherwise with the date ("Sep 26 at 10:04 AM" in English).
    public static func moment(_ date: Date, relativeTo now: Date, locale: Locale, timeZone: TimeZone,
                              calendar: Calendar) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                    timeZone: timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(time) }
        let dated = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
            .month(.abbreviated).day().hour().minute()
        return date.formatted(dated)
    }

    /// "as of 10:04 AM": always true of the numbers on screen.
    public static func asOf(_ date: Date, relativeTo now: Date, locale: Locale, timeZone: TimeZone,
                            calendar: Calendar) -> String {
        "as of " + moment(date, relativeTo: now, locale: locale, timeZone: timeZone, calendar: calendar)
    }

    /// "Log in again, last known as of 10:04 AM", or the note alone when
    /// there are no last known numbers.
    public static func noteLine(_ note: String, lastKnownAt: Date?, relativeTo now: Date, locale: Locale,
                                timeZone: TimeZone, calendar: Calendar) -> String {
        guard let lastKnownAt else { return note }
        return "\(note), last known " + asOf(lastKnownAt, relativeTo: now, locale: locale, timeZone: timeZone,
                                              calendar: calendar)
    }
}
