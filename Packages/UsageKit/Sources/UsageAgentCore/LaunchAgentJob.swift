import Foundation

/// The agent's launchd job: `LaunchAgent/com.vishutdhar.usagewidget.agent.plist`,
/// copied into the app at Contents/Library/LaunchAgents and registered with
/// SMAppService.agent. launchd starts it at login and starts it again after
/// a crash, an outside kill or a non-zero exit; a clean exit (the status
/// window's Quit) leaves it stopped until the next login or a manual open.
public enum LaunchAgentJob {
    public static let label = "com.vishutdhar.usagewidget.agent"
    public static let plistName = label + ".plist"
    /// Passed by the job's ProgramArguments, so the app knows launchd
    /// started it and behaves as at login: no status window.
    public static let argument = "--launched-by-launchd"

    /// The job's pid from `launchctl print gui/<uid>/<label>`: the
    /// top-level "pid = N" line (one tab deep); nil when it is not running.
    public static func pid(inPrint text: String) -> Int32? {
        for line in text.split(separator: "\n") where line.hasPrefix("\tpid = ") {
            return Int32(line.dropFirst("\tpid = ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    public static func startedByLaunchd(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(argument)
    }
}

extension LaunchAction {
    /// The exit status for an action that leaves at once. A copy launchd
    /// did not start leaves cleanly (0); launchd's own copy that found the
    /// lock held leaves with EX_TEMPFAIL, so KeepAlive tries it again.
    public var exitStatus: Int32? {
        switch self {
        case .handOverAndExit, .exitQuietly: return 0
        case .leaveForRetry: return 75
        case .run, .stayWithoutPolling: return nil
        }
    }
}

/// How the agent ends, and the exit status launchd sees. Only a stop the
/// person confirmed in the status window, or the end of their session,
/// exits 0; launchd restarts the agent after every other exit, so a stray
/// automated click or a quit Apple Event cannot stop it unnoticed.
public enum AgentTermination: Equatable, Sendable {
    /// Stop, confirmed in the status window (or asked for by `stopArgument`).
    case stop
    /// Log out, restart or shut down.
    case sessionEnd
    /// Any other quit.
    case unrequested

    /// The quit Apple Event's reasons for the end of a session: log out,
    /// log out without asking, restart, shut down, and the restart and
    /// shut down dialogs.
    static let sessionEndReasons: Set<String> = ["logo", "rlgo", "rest", "shut", "rrst", "rsdn"]

    public static func classify(stopConfirmed: Bool, quitReason: UInt32?) -> AgentTermination {
        if stopConfirmed { return .stop }
        if let quitReason, sessionEndReasons.contains(fourCharacters(quitReason)) { return .sessionEnd }
        return .unrequested
    }

    public var exitStatus: Int32 {
        switch self {
        case .stop, .sessionEnd: return 0
        case .unrequested: return 1
        }
    }

    static func fourCharacters(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }
}

extension LaunchAgentJob {
    /// Run the app's executable with this to stop the running agent as a
    /// confirmed Stop would (the install script uses it); it posts
    /// `stopNotification`, which the running copy observes.
    public static let stopArgument = "--stop"
    public static let stopNotification = "com.vishutdhar.usagewidget.stop"
    /// The answer of the copy holding the lock.
    public static let answerNotification = "com.vishutdhar.usagewidget.answer"
    /// Registers the job again from a newly installed copy (the install
    /// script); exits 0 when registered, 3 when left off by the person's
    /// choice or awaiting approval, 4 when registration failed.
    public static let registerArgument = "--register-job"
}
