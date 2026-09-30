import XCTest
@testable import UsageCore

final class BarGeometryTests: XCTestCase {
    func testFillWidth() {
        XCTAssertEqual(BarGeometry.fillWidth(barWidth: 200, fraction: 0), 0)
        XCTAssertEqual(BarGeometry.fillWidth(barWidth: 200, fraction: 0.001), 6, "any usage shows one round cap")
        XCTAssertEqual(BarGeometry.fillWidth(barWidth: 200, fraction: 0.5), 100)
        XCTAssertEqual(BarGeometry.fillWidth(barWidth: 200, fraction: 1.3), 200, "clamped to the bar")
        XCTAssertEqual(BarGeometry.fillWidth(barWidth: 200, fraction: -1), 0)
        XCTAssertEqual(BarGeometry.fillWidth(barWidth: 4, fraction: 0.5), 4, "the cap never overflows a tiny bar")
    }

    func testTickStaysInsideTheBar() {
        XCTAssertEqual(BarGeometry.tickX(barWidth: 200, paceFraction: 0.5), 99.25)
        XCTAssertEqual(BarGeometry.tickX(barWidth: 200, paceFraction: 0), 0)
        XCTAssertEqual(BarGeometry.tickX(barWidth: 200, paceFraction: 1), 198.5)
        XCTAssertEqual(BarGeometry.tickX(barWidth: 200, paceFraction: 2), 198.5)
    }
}
