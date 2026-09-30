import Foundation
import UsageCore

/// When the agent may launch `codex app-server`. Each launch leaves an
/// empty temporary folder in ~/.codex/.tmp (the CLI's own doing), so calls
/// are kept few: once at start; then only while Codex is idle (no rollout
/// reading within the last hour) and three hours after the last call; and
/// every six hours for the banked reset count, which changes over days.
/// Never more than eight in any 24 hours, counted from a log on disk so a
/// restart cannot reset it.
public enum CodexCallPolicy {
    /// Without a rollout reading this recent, Codex is idle.
    public static let idleAfter: TimeInterval = 60 * 60
    /// The shortest gap between calls while Codex is idle.
    public static let spacing: TimeInterval = 3 * 3600
    /// The reset count is refreshed this often whatever the rollouts say.
    public static let countRefresh: TimeInterval = 6 * 3600
    public static let dailyCeiling = 8
    public static let window: TimeInterval = 24 * 3600

    public enum Reason: String, Sendable {
        case start
        case codexIdle = "codex-idle"
        case countRefresh = "count-refresh"
    }

    /// The calls still inside the 24 hour window. One dated ahead (a clock
    /// set back) counts as just made.
    public static func recent(_ calls: [SchedulerClock], now: SchedulerClock) -> [SchedulerClock] {
        calls.filter { now.seconds(since: $0) < window }
    }

    /// Why a call may go now, or nil.
    /// - Parameters:
    ///   - calls: every call in the log, oldest first.
    ///   - firstOfLaunch: no call has been made (or counted) since launch.
    ///   - newestRollout: when the newest rollout reading was measured.
    public static func reason(calls: [SchedulerClock], firstOfLaunch: Bool, newestRollout: Date?,
                              now: SchedulerClock) -> Reason? {
        guard recent(calls, now: now).count < dailyCeiling else { return nil }
        if firstOfLaunch { return .start }
        guard let last = calls.last else { return .start }
        let since = now.seconds(since: last)
        if since >= countRefresh { return .countRefresh }
        let idle = newestRollout.map { now.wall.timeIntervalSince($0) > idleAfter } ?? true
        return idle && since >= spacing ? .codexIdle : nil
    }

    /// The earliest moment a call could go, by the spacing and the ceiling
    /// (it also needs Codex to be idle before the six hour refresh).
    public static func nextEligible(calls: [SchedulerClock], now: SchedulerClock) -> Date {
        var ready = now.wall
        if let last = calls.last {
            ready = max(ready, now.wall.addingTimeInterval(max(0, spacing - now.seconds(since: last))))
        }
        let inWindow = recent(calls, now: now)
        if inWindow.count >= dailyCeiling, let oldest = inWindow.min(by: { now.seconds(since: $0) > now.seconds(since: $1) }) {
            ready = max(ready, now.wall.addingTimeInterval(window - now.seconds(since: oldest)))
        }
        return ready
    }
}

/// The app-server calls of the last day, beside the reload state.
public struct CodexCallLog: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = CodexCallLog.currentVersion
    public var calls: [SchedulerClock]

    public init(calls: [SchedulerClock] = []) {
        self.calls = calls
    }
}

public enum CodexCallLogStore {
    public static let fileName = "codex-calls.json"

    public enum ReadResult: Equatable, Sendable {
        case missing
        case loaded(CodexCallLog)
        case unreadable(String)
    }

    public static func read(from url: URL) -> ReadResult {
        let data: Data
        switch SafeFile.read(url) {
        case .data(let contents): data = contents
        case .missing: return .missing
        case .refused(let reason): return .unreadable(Redactor.redactEmails(reason))
        }
        guard let log = try? decoder.decode(CodexCallLog.self, from: data), log.version == CodexCallLog.currentVersion else {
            return .unreadable("not a Codex call log")
        }
        return .loaded(log)
    }

    public static func write(_ log: CodexCallLog, to url: URL) throws {
        try AtomicFile.write(try encoder.encode(log), to: url)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
