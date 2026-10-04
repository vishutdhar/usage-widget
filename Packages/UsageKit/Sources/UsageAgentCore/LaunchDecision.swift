import Foundation
import UsageCore

public enum LaunchAction: Equatable, Sendable {
    /// This copy holds the lock: run the agent.
    case run
    /// Another copy runs the agent: ask it to show its window, then quit.
    case handOverAndExit
    /// A login launch found a copy already running: quit without a window.
    case exitQuietly
    /// launchd's copy found another copy holding the lock after waiting:
    /// leave with a non-zero status, so KeepAlive tries again.
    case leaveForRetry
    /// The lock itself failed: stay open with the reason shown, without polling.
    case stayWithoutPolling(String)
}

/// What a newly launched copy of the app does, given the agent lock and
/// whether macOS opened it at login.
public enum LaunchDecision {
    /// The login check comes before the handover: a duplicate login launch
    /// must not open the running copy's window.
    public static func decide(lock: InstanceLock.Outcome.Kind, loginLaunch: Bool,
                              startedByLaunchd: Bool = false) -> LaunchAction {
        switch lock {
        case .acquired:
            return .run
        case .heldElsewhere:
            if startedByLaunchd { return .leaveForRetry }
            return loginLaunch ? .exitQuietly : .handOverAndExit
        case .failed(let reason):
            // launchd's copy leaves for a retry (`retryNote` logs why): staying up without polling,
            // it would keep the job running and KeepAlive would never retry.
            if startedByLaunchd { return .leaveForRetry }
            return .stayWithoutPolling("Could not take the agent lock: \(Redactor.redactEmails(reason))")
        }
    }

    /// What launchd's copy logs as it leaves for a retry after a lock
    /// error, masked; nil when the lock is merely held by another copy.
    public static func retryNote(lock: InstanceLock.Outcome.Kind) -> String? {
        guard case .failed(let reason) = lock else { return nil }
        return "agent lock failed: \(Redactor.redactEmails(reason)); leaving for a retry"
    }
}
