import XCTest
import UsageCore
@testable import UsageAgentCore

final class LaunchDecisionTests: XCTestCase {
    func testTheLockHolderRuns() {
        XCTAssertEqual(LaunchDecision.decide(lock: .acquired, loginLaunch: false), .run)
        XCTAssertEqual(LaunchDecision.decide(lock: .acquired, loginLaunch: true), .run)
    }

    func testAnOpenedCopyHandsOverToTheRunningOne() {
        XCTAssertEqual(LaunchDecision.decide(lock: .heldElsewhere, loginLaunch: false), .handOverAndExit)
    }

    func testADuplicateLoginLaunchLeavesQuietly() {
        XCTAssertEqual(LaunchDecision.decide(lock: .heldElsewhere, loginLaunch: true), .exitQuietly,
                       "no status window pops up at login because a copy already runs")
    }

    func testALockErrorKeepsTheAppOpenWithoutPolling() {
        XCTAssertEqual(LaunchDecision.decide(lock: .failed("Is a directory"), loginLaunch: false),
                       .stayWithoutPolling("Could not take the agent lock: Is a directory"))
        XCTAssertEqual(LaunchDecision.decide(lock: .failed("Is a directory"), loginLaunch: true),
                       .stayWithoutPolling("Could not take the agent lock: Is a directory"))
    }

    func testLockErrorTextIsMasked() {
        XCTAssertEqual(LaunchDecision.decide(lock: .failed("denied under /Users/alex@example.com"), loginLaunch: false),
                       .stayWithoutPolling("Could not take the agent lock: denied under /Us***@***.com"),
                       "the address is hidden; the pattern treats the path as part of the name")
    }
}
