import XCTest
import UsageCore
@testable import UsageAgentCore

/// The agent runs as a launchd job so a crash or an outside kill restarts
/// it, while the person's own Quit (exit status 0) leaves it stopped.
final class LaunchAgentJobTests: XCTestCase {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func plist() throws -> [String: Any] {
        let url = Self.repository.appendingPathComponent("LaunchAgent").appendingPathComponent(LaunchAgentJob.plistName)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testThePlistNamesTheJobAndTheAppExecutable() throws {
        let job = try plist()
        XCTAssertEqual(job["Label"] as? String, LaunchAgentJob.label)
        XCTAssertEqual(LaunchAgentJob.plistName, LaunchAgentJob.label + ".plist")
        XCTAssertEqual(job["BundleProgram"] as? String, "Contents/MacOS/Usage Widget")
        XCTAssertEqual(job["ProgramArguments"] as? [String], ["Usage Widget", LaunchAgentJob.argument])
        XCTAssertEqual(job["AssociatedBundleIdentifiers"] as? [String], ["com.vishutdhar.usagewidget"])
        XCTAssertEqual(job["LimitLoadToSessionType"] as? String, "Aqua")
    }

    /// Restarted after anything but a clean exit: a crash, a kill from
    /// outside, or a non-zero status. A clean exit (the Quit button) stays.
    func testOnlyAnUnsuccessfulExitIsRestarted() throws {
        let job = try plist()
        let keepAlive = try XCTUnwrap(job["KeepAlive"] as? [String: Any])
        XCTAssertEqual(keepAlive.count, 1, "no other keep-alive condition")
        XCTAssertEqual(keepAlive["SuccessfulExit"] as? Bool, false)
        XCTAssertEqual(job["RunAtLoad"] as? Bool, true, "starts at login")
    }

    func testOnlyTheJobsArgumentMarksALaunchdStart() {
        XCTAssertTrue(LaunchAgentJob.startedByLaunchd(arguments: ["/Applications/Usage Widget.app/Contents/MacOS/Usage Widget",
                                                                  LaunchAgentJob.argument]))
        XCTAssertFalse(LaunchAgentJob.startedByLaunchd(arguments: ["/Applications/Usage Widget.app/Contents/MacOS/Usage Widget"]))
        XCTAssertFalse(LaunchAgentJob.startedByLaunchd(arguments: [LaunchAgentJob.argument]),
                       "the program name is not an argument")
        XCTAssertFalse(LaunchAgentJob.startedByLaunchd(arguments: []))
    }

    /// Leaving because another copy runs is a clean exit, so launchd does
    /// not start the job again and again while that copy holds the lock.
    func testLeavingForAnotherCopyIsACleanExit() {
        XCTAssertEqual(LaunchAction.handOverAndExit.exitStatus, 0)
        XCTAssertEqual(LaunchAction.exitQuietly.exitStatus, 0)
        XCTAssertNil(LaunchAction.run.exitStatus)
        XCTAssertNil(LaunchAction.stayWithoutPolling("x").exitStatus)
    }
}
