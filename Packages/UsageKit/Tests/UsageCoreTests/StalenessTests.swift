import XCTest
@testable import UsageCore

final class StalenessTests: XCTestCase {
    let measured = utc(2026, 9, 27, 12, 0, 0)

    func testDimmingStartsAfterTwoHours() {
        XCTAssertEqual(Staleness.dimAfter, 2 * 3600)
        XCTAssertFalse(Staleness.isDimmed(fetchedAt: measured, at: measured, provider: "claude"))
        XCTAssertFalse(Staleness.isDimmed(fetchedAt: measured, at: measured.addingTimeInterval(2 * 3600), provider: "claude"))
        XCTAssertTrue(Staleness.isDimmed(fetchedAt: measured, at: measured.addingTimeInterval(2 * 3600 + 1), provider: "claude"))
    }

    func testUnknownMeasurementIsNotDimmed() {
        XCTAssertFalse(Staleness.isDimmed(fetchedAt: nil, at: measured, provider: "claude"))
    }

    func testAMeasurementFromTheFutureIsNotDimmed() {
        XCTAssertFalse(Staleness.isDimmed(fetchedAt: measured.addingTimeInterval(3600), at: measured, provider: "claude"))
    }
}
