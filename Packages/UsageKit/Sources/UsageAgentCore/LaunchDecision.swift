import Foundation
import UsageCore

public enum LaunchAction: Equatable, Sendable {
    /// This copy holds the lock: run the agent.
    case run
    /// Another copy runs the agent: ask it to show its window, then quit.
    case handOverAndExit
    /// A login launch found a copy already running: quit without a window.
    case exitQuietly
    /// The lock itself failed: stay open with the reason shown, without polling.
    case stayWithoutPolling(String)
}

/// What a newly launched copy of the app does, given the agent lock and
/// whether macOS opened it at login.
public enum LaunchDecision {
    /// The login check comes before the handover: a duplicate login launch
    /// must not open the running copy's window.
    public static func decide(lock: InstanceLock.Outcome.Kind, loginLaunch: Bool) -> LaunchAction {
        switch lock {
        case .acquired:
            return .run
        case .heldElsewhere:
            return loginLaunch ? .exitQuietly : .handOverAndExit
        case .failed(let reason):
            return .stayWithoutPolling("Could not take the agent lock: \(Redactor.redactEmails(reason))")
        }
    }
}
