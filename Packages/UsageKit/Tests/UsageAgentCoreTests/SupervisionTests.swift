import XCTest
import UsageCore
@testable import UsageAgentCore

/// The copy that runs the agent is always launchd's, so a crash is
/// restarted and Start at login off stops it. A copy opened by hand hands
/// over to the job; it runs the agent itself only when the job cannot, and
/// then says why.
final class SupervisionTests: XCTestCase {
    /// Scripted effects: kickstart's status, and what each probe of the
    /// lock finds.
    final class Effects {
        var withForeignHolder: Effects {
            alive.insert(901)
            probes = Array(repeating: .heldBy(901), count: 40)
            return self
        }

        var calls: [String] = []
        var startStatus: Int32 = 0
        var probes: [LockProbe] = []
        var alive: Set<Int32> = [900]
        var jobPid: Int32? = 900
        var slept: TimeInterval = 0

        var value: Takeover.Effects {
            Takeover.Effects(
                startJob: { self.calls.append("start"); return self.startStatus },
                releaseOwnLock: { self.calls.append("release") },
                probe: {
                    self.calls.append("probe")
                    return self.probes.isEmpty ? .free : self.probes.removeFirst()
                },
                isAlive: { self.alive.contains($0) },
                jobPid: { self.jobPid },
                sleep: { self.slept += $0 })
        }
    }

    let own: Int32 = 500

    func testTheJobsPidIsReadFromLaunchctl() {
        let print = "gui/501/com.vishutdhar.usagewidget.agent = {\n\tactive count = 1\n\tstate = running\n\tpid = 43085\n\tlast exit code = 0\n}\n"
        XCTAssertEqual(LaunchAgentJob.pid(inPrint: print), 43085)
        XCTAssertNil(LaunchAgentJob.pid(inPrint: "gui/501/x = {\n\tstate = not running\n}\n"))
        XCTAssertNil(LaunchAgentJob.pid(inPrint: "\t\tpid = 12\n"), "a nested pid is not the job's")
    }

    func testATakeoverIsConfirmedWhenAnotherLiveProcessHoldsTheLock() {
        let effects = Effects()
        effects.probes = [.free, .heldBy(own), .heldBy(900)]
        XCTAssertEqual(Takeover.run(ownPid: own, effects: effects.value), .confirmed(900))
        XCTAssertEqual(effects.calls, ["start", "release", "probe", "probe", "probe"],
                       "started first, the lock let go only after kickstart worked")
    }

    func testAFailedKickstartKeepsTheLock() {
        let effects = Effects()
        effects.startStatus = 113
        XCTAssertEqual(Takeover.run(ownPid: own, effects: effects.value), .jobNotStarted(113))
        XCTAssertEqual(effects.calls, ["start"], "nothing let go, nothing probed")
    }

    /// No other process takes the lock within the window: not handed over.
    /// A holder whose pid is gone, or is this process, does not count.
    func testALockNeverTakenByAnotherProcessIsNotATakeover() {
        let effects = Effects()
        effects.alive.insert(own)  // this process is alive, as it is in fact
        effects.probes = [.heldBy(own), .heldBy(901), .heldBy(nil)]
        XCTAssertEqual(Takeover.run(ownPid: own, effects: effects.value), .notTaken)
        XCTAssertEqual(effects.slept, Takeover.window, accuracy: 0.001)
    }

    /// Another copy holding the lock (an older build, or one running
    /// unsupervised) is not the job: no handover, and the copy says why.
    func testAForeignHolderIsNotATakeover() {
        let effects = Effects()
        effects.alive.insert(901)
        effects.probes = Array(repeating: .heldBy(901), count: 40)
        XCTAssertEqual(Takeover.run(ownPid: own, effects: effects.value), .notTaken)
        XCTAssertEqual(ManualOpen.run(readiness: .ready, ownPid: own, effects: Effects().withForeignHolder.value),
                       .runUnsupervised(ManualOpen.notTakenNote))
        effects.jobPid = nil
        effects.probes = [.heldBy(900)]
        XCTAssertEqual(Takeover.run(ownPid: own, effects: effects.value), .notTaken, "no job pid, no confirmation")
    }

    func testAnOpenedCopyHandsOverOnlyOnAConfirmedTakeover() {
        let effects = Effects()
        effects.probes = [.heldBy(900)]
        XCTAssertEqual(ManualOpen.run(readiness: .ready, ownPid: own, effects: effects.value), .handedOver)
    }

    func testAnOpenedCopyKeepsRunningWhenKickstartFails() {
        let effects = Effects()
        effects.startStatus = 5
        XCTAssertEqual(ManualOpen.run(readiness: .ready, ownPid: own, effects: effects.value),
                       .runUnsupervised("Not supervised: launchd could not start the agent (launchctl exit 5), so a crash is not restarted."))
    }

    func testAnOpenedCopyKeepsRunningWhenNobodyTakesTheLock() {
        let effects = Effects()
        XCTAssertEqual(ManualOpen.run(readiness: .ready, ownPid: own, effects: effects.value),
                       .runUnsupervised(ManualOpen.notTakenNote))
    }

    func testAJobThatCannotRunLeavesTheOpenedCopyRunningWithTheReason() {
        let effects = Effects()
        XCTAssertEqual(ManualOpen.run(readiness: .unavailable("Start at login is off"), ownPid: own, effects: effects.value),
                       .runUnsupervised("Not supervised: Start at login is off, so a crash is not restarted."))
        XCTAssertEqual(effects.calls, [], "nothing started, nothing probed")
    }

    /// launchd's copy that never gets the lock exits non-zero, so KeepAlive
    /// tries it again; leaving with 0 would leave the job stopped for good.
    func testLaunchdsCopyLeavesForARetry() {
        let action = LaunchDecision.decide(lock: .heldElsewhere, loginLaunch: true, startedByLaunchd: true)
        XCTAssertEqual(action, .leaveForRetry)
        XCTAssertNotEqual(action.exitStatus, 0)
        XCTAssertNotNil(action.exitStatus)
        XCTAssertEqual(LaunchDecision.decide(lock: .heldElsewhere, loginLaunch: true, startedByLaunchd: false), .exitQuietly)
        XCTAssertEqual(LaunchDecision.decide(lock: .acquired, loginLaunch: true, startedByLaunchd: true), .run)
    }

    // MARK: taking the lock back after a handover that did not happen

    final class Recovery {
        var outcomes: [InstanceLock.Outcome.Kind] = []
        var calls: [String] = []
        lazy var value = LockRecovery(
            acquire: { self.calls.append("acquire"); return self.outcomes.removeFirst() },
            resume: { self.calls.append("resume") },
            leave: { self.calls.append("leave") },
            show: { self.calls.append("show \($0)") })
    }

    /// No poll without the lock: a failed reacquisition stays paused and
    /// says so; the next minute's attempt that succeeds resumes polling.
    func testPollingResumesOnlyWithTheLockBack() {
        let recovery = Recovery()
        recovery.outcomes = [.failed("Input/output error"), .acquired, .acquired]
        recovery.value.attempt()
        XCTAssertEqual(recovery.calls, ["acquire",
                                        "show Could not take the agent lock back (Input/output error); polling is paused and tried again every minute."])
        XCTAssertTrue(recovery.value.paused)
        recovery.calls = []
        recovery.value.attempt()
        XCTAssertEqual(recovery.calls, ["acquire", "resume"])
        XCTAssertFalse(recovery.value.paused)
        recovery.value.attempt()
        XCTAssertEqual(recovery.calls, ["acquire", "resume"], "nothing to do once it holds the lock")
    }

    func testALockTakenByAnotherCopyMeansLeaving() {
        let recovery = Recovery()
        recovery.outcomes = [.heldElsewhere]
        recovery.value.attempt()
        XCTAssertEqual(recovery.calls, ["acquire", "leave"])
    }

    // MARK: the launchd copy's lock

    /// A copy handing over exits just after starting the job; launchd's
    /// copy waits for the lock instead of leaving at once.
    func testLaunchdsCopyWaitsForTheLock() {
        var tries = 0
        var slept: [TimeInterval] = []
        let kind = LaunchDecision.acquire(retrying: true, attempt: {
            tries += 1
            return tries < 4 ? .heldElsewhere : .acquired
        }, sleep: { slept.append($0) })
        XCTAssertEqual(kind, .acquired)
        XCTAssertEqual(tries, 4)
        XCTAssertEqual(slept.count, 3)
    }

    func testLaunchdsCopyGivesUpAfterTheWindow() {
        var tries = 0
        var waited: TimeInterval = 0
        let kind = LaunchDecision.acquire(retrying: true, attempt: { tries += 1; return .heldElsewhere },
                                          sleep: { waited += $0 })
        XCTAssertEqual(kind, .heldElsewhere)
        XCTAssertEqual(waited, LaunchDecision.lockWait, accuracy: 0.001)
    }

    func testOtherCopiesAndErrorsDoNotWait() {
        var tries = 0
        XCTAssertEqual(LaunchDecision.acquire(retrying: false, attempt: { tries += 1; return .heldElsewhere },
                                              sleep: { _ in XCTFail("no wait") }), .heldElsewhere)
        XCTAssertEqual(LaunchDecision.acquire(retrying: true, attempt: { tries += 1; return .failed("EIO") },
                                              sleep: { _ in XCTFail("no wait") }), .failed("EIO"))
        XCTAssertEqual(tries, 2)
    }
}
