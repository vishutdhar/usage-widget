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

    /// launchd's copy that cannot use the lock (a passing EIO, say) leaves
    /// with a non-zero status so KeepAlive starts it again, instead of
    /// staying up without polling where launchd would never retry it.
    func testALaunchdCopyWithALockErrorLeavesForARetry() throws {
        let action = LaunchDecision.decide(lock: .failed("Input/output error"), loginLaunch: true, startedByLaunchd: true)
        XCTAssertEqual(action, .leaveForRetry)
        XCTAssertNotEqual(try XCTUnwrap(action.exitStatus, "it leaves at once"), 0)
        XCTAssertEqual(LaunchDecision.retryNote(lock: .failed("Input/output error at /Users/alex@example.com")),
                       "agent lock failed: Input/output error at /Us***@***.com; leaving for a retry",
                       "the log says why, masked")
        XCTAssertNil(LaunchDecision.retryNote(lock: .heldElsewhere), "a holder is not an error")
    }

    func testLockErrorTextIsMasked() {
        XCTAssertEqual(LaunchDecision.decide(lock: .failed("denied under /Users/alex@example.com"), loginLaunch: false),
                       .stayWithoutPolling("Could not take the agent lock: denied under /Us***@***.com"),
                       "the address is hidden; the pattern treats the path as part of the name")
    }
}
