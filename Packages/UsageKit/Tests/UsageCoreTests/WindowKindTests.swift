import XCTest
@testable import UsageCore

final class WindowKindTests: XCTestCase {
    func testClassifiesByLength() {
        XCTAssertEqual(UsageWindow.Kind.classify(windowSeconds: 18_000, modelScoped: false), .session)
        XCTAssertEqual(UsageWindow.Kind.classify(windowSeconds: 86_399, modelScoped: false), .session)
        XCTAssertEqual(UsageWindow.Kind.classify(windowSeconds: 86_400, modelScoped: false), .weekly)
        XCTAssertEqual(UsageWindow.Kind.classify(windowSeconds: 604_800, modelScoped: false), .weekly)
    }

    func testModelScopedWinsOverLength() {
        XCTAssertEqual(UsageWindow.Kind.classify(windowSeconds: 604_800, modelScoped: true), .model)
        XCTAssertEqual(UsageWindow.Kind.classify(windowSeconds: 18_000, modelScoped: true), .model)
    }

    func testShortNames() {
        XCTAssertEqual(WindowLength.shortName(seconds: 18_000), "5h")
        XCTAssertEqual(WindowLength.shortName(seconds: 604_800), "7d")
        XCTAssertEqual(WindowLength.shortName(seconds: 86_400), "1d")
        XCTAssertEqual(WindowLength.shortName(seconds: 2_700), "45m")
        XCTAssertEqual(WindowLength.shortName(seconds: 5_400), "90m")
    }
}
