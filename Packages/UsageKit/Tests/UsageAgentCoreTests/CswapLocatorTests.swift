import XCTest
@testable import UsageAgentCore

final class CswapLocatorTests: XCTestCase {
    let locator = CswapLocator(home: URL(fileURLWithPath: "/Users/someone"))

    func testCandidateOrder() {
        XCTAssertEqual(locator.candidates.map(\.path), [
            "/Users/someone/.local/bin/cswap",
            "/opt/homebrew/bin/cswap",
            "/usr/local/bin/cswap",
        ])
    }

    func testFirstExecutableCandidateWins() {
        XCTAssertEqual(locator.resolve { _ in true }?.path, "/Users/someone/.local/bin/cswap")
        XCTAssertEqual(locator.resolve { $0.path.hasPrefix("/opt") || $0.path.hasPrefix("/usr") }?.path,
                       "/opt/homebrew/bin/cswap")
        XCTAssertEqual(locator.resolve { $0.path.hasPrefix("/usr") }?.path, "/usr/local/bin/cswap")
    }

    func testNothingInstalled() {
        XCTAssertNil(locator.resolve { _ in false })
    }
}
