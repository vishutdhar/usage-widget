import XCTest
@testable import UsageCore

final class ISODateTests: XCTestCase {
    func testParsesCswapMicrosecondsWithOffset() throws {
        let date = try XCTUnwrap(ISODate.parse("2026-01-15T14:00:00.123456+00:00"))
        XCTAssertEqual(date.timeIntervalSince1970, utc(2026, 1, 15, 14, 0, 0, frac: 0.123456).timeIntervalSince1970, accuracy: 0.000_01)
    }

    func testParsesZuluWithoutFraction() {
        XCTAssertEqual(ISODate.parse("2026-01-15T10:00:00Z"), utc(2026, 1, 15, 10, 0, 0))
    }

    func testParsesNonUTCOffsets() {
        XCTAssertEqual(ISODate.parse("2026-01-15T15:30:00+05:30"), utc(2026, 1, 15, 10, 0, 0))
        XCTAssertEqual(ISODate.parse("2026-01-15T06:00:00-0400"), utc(2026, 1, 15, 10, 0, 0))
    }

    func testRejectsGarbage() {
        XCTAssertNil(ISODate.parse(""))
        XCTAssertNil(ISODate.parse("yesterday"))
        XCTAssertNil(ISODate.parse("2026-13-40T99:99:99Z"))
    }

    func testFormatsUTCWithMilliseconds() {
        XCTAssertEqual(ISODate.format(utc(2026, 1, 15, 14, 0, 0, frac: 0.125)), "2026-01-15T14:00:00.125Z")
    }

    func testRoundTripsToTheMillisecond() throws {
        let date = utc(2026, 1, 2, 3, 4, 5, frac: 0.25)
        XCTAssertEqual(try XCTUnwrap(ISODate.parse(ISODate.format(date))), date)
    }
}
