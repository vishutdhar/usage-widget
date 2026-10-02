import Foundation
import UsageCore

/// Whether the launchd job can run the agent, or why not.
public enum JobReadiness: Equatable, Sendable {
    case ready
    case unavailable(String)
}

/// A copy opened by hand (not by launchd) hands the agent over to the
/// launchd job, so the running copy is always the supervised one: a crash
/// is restarted and Start at login off stops it. It leaves only on a
/// confirmed takeover (`Takeover`); otherwise it runs the agent itself and
/// the status window says why.
public enum ManualOpen {
    public enum Outcome: Equatable, Sendable {
        case handedOver
        case runUnsupervised(String)
    }

    public static let notTakenNote = "Not supervised: launchd's copy did not take over, so a crash is not restarted."

    public static func note(for reason: String) -> String {
        "Not supervised: \(reason), so a crash is not restarted."
    }

    public static func run(readiness: JobReadiness, ownPid: Int32, effects: Takeover.Effects) -> Outcome {
        if case .unavailable(let reason) = readiness { return .runUnsupervised(note(for: reason)) }
        switch Takeover.run(ownPid: ownPid, effects: effects) {
        case .confirmed:
            return .handedOver
        case .jobNotStarted(let status):
            return .runUnsupervised(note(for: "launchd could not start the agent (launchctl exit \(status))"))
        case .notTaken:
            return .runUnsupervised(notTakenNote)
        }
    }
}

/// Starts the launchd job and confirms its copy took the agent lock. The
/// caller's own lock (a copy running unsupervised has one) is let go only
/// after kickstart worked; a takeover counts only when the job's own live
/// process (its pid from launchctl) holds the lock within `window`.
public enum Takeover {
    public struct Effects {
        /// `launchctl kickstart`'s exit status (0 also when the job runs).
        public var startJob: () -> Int32
        public var releaseOwnLock: () -> Void
        public var probe: () -> LockProbe
        public var isAlive: (Int32) -> Bool
        public var jobPid: () -> Int32?
        public var sleep: (TimeInterval) -> Void

        public init(startJob: @escaping () -> Int32, releaseOwnLock: @escaping () -> Void,
                    probe: @escaping () -> LockProbe, isAlive: @escaping (Int32) -> Bool,
                    jobPid: @escaping () -> Int32?, sleep: @escaping (TimeInterval) -> Void) {
            self.startJob = startJob
            self.releaseOwnLock = releaseOwnLock
            self.probe = probe
            self.isAlive = isAlive
            self.jobPid = jobPid
            self.sleep = sleep
        }
    }

    public enum Outcome: Equatable, Sendable {
        case confirmed(Int32)
        case jobNotStarted(Int32)
        case notTaken
    }

    public static let window: TimeInterval = 15
    static let pause: TimeInterval = 0.5

    public static func run(ownPid: Int32, effects: Effects) -> Outcome {
        let status = effects.startJob()
        guard status == 0 else { return .jobNotStarted(status) }
        effects.releaseOwnLock()
        var waited: TimeInterval = 0
        while true {
            // The holder must be the job's own process: another copy (an
            // older build, or one running unsupervised) is not a takeover.
            if case .heldBy(let pid?) = effects.probe(), pid != ownPid, effects.isAlive(pid),
               let job = effects.jobPid(), job == pid {
                return .confirmed(pid)
            }
            guard waited < window - 0.0001 else { return .notTaken }
            effects.sleep(pause)
            waited += pause
        }
    }
}

extension LaunchDecision {
    /// How long launchd's copy waits for the lock: a copy handing over
    /// exits just after starting the job.
    public static let lockWait: TimeInterval = 10
    static let lockPause: TimeInterval = 0.25

    /// Takes the lock; with `retrying` (launchd's copy) a lock held
    /// elsewhere is tried again until `lockWait` has passed.
    public static func acquire(retrying: Bool, attempt: () -> InstanceLock.Outcome.Kind,
                               sleep: (TimeInterval) -> Void) -> InstanceLock.Outcome.Kind {
        var kind = attempt()
        guard retrying else { return kind }
        var waited: TimeInterval = 0
        while kind == .heldElsewhere, waited < lockWait - 0.0001 {
            sleep(lockPause)
            waited += lockPause
            kind = attempt()
        }
        return kind
    }
}


/// After a handover that did not happen, a copy that let go of the agent
/// lock takes it back before it polls again: never a poll without the lock.
/// A failure keeps polling paused and is shown; the caller tries again
/// every minute. A lock another copy took means that copy runs the agent.
public final class LockRecovery {
    public private(set) var paused = true
    private let acquire: () -> InstanceLock.Outcome.Kind
    private let resume: () -> Void
    private let leave: () -> Void
    private let show: (String) -> Void

    public init(acquire: @escaping () -> InstanceLock.Outcome.Kind, resume: @escaping () -> Void,
                leave: @escaping () -> Void, show: @escaping (String) -> Void) {
        self.acquire = acquire
        self.resume = resume
        self.leave = leave
        self.show = show
    }

    public func attempt() {
        guard paused else { return }
        switch acquire() {
        case .acquired:
            paused = false
            resume()
        case .heldElsewhere:
            leave()
        case .failed(let reason):
            show("Could not take the agent lock back (\(Redactor.redactEmails(reason))); "
                 + "polling is paused and tried again every minute.")
        }
    }
}
