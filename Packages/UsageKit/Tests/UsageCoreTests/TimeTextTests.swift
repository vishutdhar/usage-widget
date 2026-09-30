import XCTest
@testable import UsageCore

final class TimeTextTests: XCTestCase {
    let posix = Locale(identifier: "en_US_POSIX")
    let utcZone = TimeZone(identifier: "UTC")!
    let gregorian = Calendar(identifier: .gregorian)
    let now = utc(2026, 9, 27, 12, 30, 0)

    func testSameDayIsJustTheTime() {
        XCTAssertEqual(TimeText.moment(utc(2026, 9, 27, 12, 4, 0), relativeTo: now, locale: posix, timeZone: utcZone,
                                       calendar: gregorian), "12:04\u{202F}PM")
        XCTAssertEqual(TimeText.asOf(utc(2026, 9, 27, 12, 4, 0), relativeTo: now, locale: posix, timeZone: utcZone,
                                     calendar: gregorian), "as of 12:04\u{202F}PM")
    }

    func testAnotherDayAddsTheDate() {
        XCTAssertEqual(TimeText.moment(utc(2026, 9, 26, 10, 0, 0), relativeTo: now, locale: posix, timeZone: utcZone,
                                       calendar: gregorian), "Sep 26 at 10:00\u{202F}AM")
    }

    func testTheCallersLocaleAndTimeZoneAreUsed() {
        let german = TimeText.moment(utc(2026, 9, 27, 12, 4, 0), relativeTo: now, locale: Locale(identifier: "de_DE"),
                                     timeZone: utcZone, calendar: gregorian)
        XCTAssertEqual(german, "12:04")
        let tokyo = TimeText.moment(utc(2026, 9, 27, 12, 4, 0), relativeTo: now, locale: posix,
                                    timeZone: TimeZone(identifier: "Asia/Tokyo")!, calendar: gregorian)
        XCTAssertEqual(tokyo, "9:04\u{202F}PM")
    }

    func testNoteLines() {
        XCTAssertEqual(TimeText.noteLine("Log in again", lastKnownAt: utc(2026, 9, 26, 10, 0, 0), relativeTo: now,
                                         locale: posix, timeZone: utcZone, calendar: gregorian),
                       "Log in again, last known as of Sep 26 at 10:00\u{202F}AM")
        XCTAssertEqual(TimeText.noteLine("Keychain locked", lastKnownAt: nil, relativeTo: now,
                                         locale: posix, timeZone: utcZone, calendar: gregorian),
                       "Keychain locked")
    }
}
