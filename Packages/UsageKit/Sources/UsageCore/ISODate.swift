import Foundation

/// ISO 8601 timestamps as cswap writes them ("2026-01-15T14:00:00.123456+00:00",
/// "2026-01-15T10:00:00Z") and as the snapshot stores them.
public enum ISODate {
    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction](Z|+HH:MM|+HHMM)`; a missing zone is UTC.
    public static func parse(_ string: String) -> Date? {
        let pattern = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/
        guard let m = string.wholeMatch(of: pattern) else { return nil }
        guard
            let year = Int(m.1), let month = Int(m.2), let day = Int(m.3),
            let hour = Int(m.4), let minute = Int(m.5), let second = Int(m.6),
            (1...12).contains(month), (1...31).contains(day),
            (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let base = utcCalendar.date(from: components),
              utcCalendar.component(.day, from: base) == day
        else { return nil }

        var fraction = 0.0
        if let frac = m.7 {
            guard let value = Double("0" + frac) else { return nil }
            fraction = value
        }

        var offset = 0
        if let zone = m.8, zone != "Z" {
            let digits = zone.dropFirst().filter(\.isNumber)
            guard digits.count == 4,
                  let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
                  hours <= 23, minutes <= 59
            else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
        }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    /// UTC with milliseconds, for example "2026-01-15T14:00:00.125Z".
    /// A date that is not a finite number formats as the epoch rather than trapping.
    public static func format(_ date: Date) -> String {
        // Round to whole milliseconds first, so the text and the value agree.
        let raw = (date.timeIntervalSince1970 * 1000).rounded()
        let ms = raw.isFinite ? raw : 0
        let rounded = Date(timeIntervalSince1970: ms / 1000)
        let c = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: rounded)
        let millis = Int(ms.truncatingRemainder(dividingBy: 1000) + 1000) % 1000
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis
        )
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
