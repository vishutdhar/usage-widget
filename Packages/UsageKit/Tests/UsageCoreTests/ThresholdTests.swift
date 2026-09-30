import XCTest
@testable import UsageCore

final class ThresholdTests: XCTestCase {
    func testConstantsMatchCswap() {
        XCTAssertEqual(UsageThresholds.warnPct, 70)
        XCTAssertEqual(UsageThresholds.critPct, 90)
    }

    func testBoundaries() {
        let cases: [(Double, UsageLevel)] = [
            (0, .ok), (69.999, .ok),
            (70, .warn), (89.999, .warn),
            (90, .hot), (99.999, .hot),
            (100, .over), (150, .over),
        ]
        for (pct, level) in cases {
            XCTAssertEqual(UsageThresholds.level(for: pct), level, "\(pct)")
        }
    }
}
