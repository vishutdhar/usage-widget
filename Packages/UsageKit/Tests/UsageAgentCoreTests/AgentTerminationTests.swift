import XCTest
import UsageCore
@testable import UsageAgentCore

/// launchd restarts the agent after any exit but a clean one, so only a
/// stop the person confirmed (or the end of their session) exits 0. A quit
/// from anywhere else, such as a stray automated click or a quit Apple
/// Event, exits 1 and the agent comes back.
final class AgentTerminationTests: XCTestCase {
    func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    func testAConfirmedStopIsClean() {
        XCTAssertEqual(AgentTermination.classify(stopConfirmed: true, quitReason: nil), .stop)
        XCTAssertEqual(AgentTermination.stop.exitStatus, 0)
    }

    func testAnyOtherQuitIsRestarted() {
        XCTAssertEqual(AgentTermination.classify(stopConfirmed: false, quitReason: nil), .unrequested)
        XCTAssertEqual(AgentTermination.classify(stopConfirmed: false, quitReason: code("xxxx")), .unrequested)
        XCTAssertEqual(AgentTermination.unrequested.exitStatus, 1)
    }

    /// Logging out, restarting or shutting down quits every app; that is
    /// a clean exit, not one to undo.
    func testTheEndOfTheSessionIsClean() {
        for reason in ["logo", "rlgo", "rest", "shut", "rrst", "rsdn"] {
            XCTAssertEqual(AgentTermination.classify(stopConfirmed: false, quitReason: code(reason)), .sessionEnd, reason)
        }
        XCTAssertEqual(AgentTermination.sessionEnd.exitStatus, 0)
    }

    func testAConfirmedStopWinsOverAReason() {
        XCTAssertEqual(AgentTermination.classify(stopConfirmed: true, quitReason: code("logo")), .stop)
    }

    func testTheStopArgumentIsItsOwn() {
        XCTAssertNotEqual(LaunchAgentJob.stopArgument, LaunchAgentJob.argument)
        XCTAssertTrue(LaunchAgentJob.stopArgument.hasPrefix("--"))
    }
}
