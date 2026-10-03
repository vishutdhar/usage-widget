import Foundation

/// What the scheduler remembers between polls and across restarts
/// (`reload-state.json` beside the snapshot).
public struct ReloadState: Codable, Equatable, Sendable {
    /// Files written by an older build carry another version and are replaced.
    public static let currentVersion = 2

    public var version = ReloadState.currentVersion
    public var lastRequest: SchedulerClock?
    /// What the widget was last asked to show. Changes are measured against
    /// this, not against the previous poll, so a held change is never lost.
    public var requested: DisplayFingerprint?
    public var pending: Bool
    public var pendingSince: Date?
    /// Requests in the rolling 24 hours.
    public var requests: [SchedulerClock]
    /// The last completion reload given to a press: it counts toward the
    /// cap, and such reloads are at most one every 10 minutes. Absent in
    /// older files.
    public var lastCapExemption: SchedulerClock?
    /// The last request's number, for the reload log.
    public var lastRequestId: Int?
    /// The reload bucket's tokens when last counted, and when that was
    /// (`ReloadBucket`). Absent in older files: the bucket starts full.
    public var bucketTokens: Double?
    public var bucketAt: SchedulerClock?

    public init(lastRequest: SchedulerClock? = nil, requested: DisplayFingerprint? = nil, pending: Bool = false,
                pendingSince: Date? = nil, requests: [SchedulerClock] = []) {
        self.lastRequest = lastRequest
        self.requested = requested
        self.pending = pending
        self.pendingSince = pendingSince
        self.requests = requests
    }
}

public struct ReloadDecision: Equatable, Sendable {
    public enum Hold: String, Sendable {
        /// Too soon after the last request.
        case spacing
        /// The cap's worth of requests already in the last 24 hours.
        case cap
        /// The reload bucket is empty until its next token.
        case tokens
    }

    public var fire: Bool
    public var reasons: [ReloadReason]
    public var urgent: Bool
    public var hold: Hold?
    /// The number of the request made, when one was.
    public var id: Int?
}

/// Spends WidgetKit's reload budget (typically 40 to 70 a day) on what a
/// person would notice in the background: urgent and ordinary changes after
/// 10 minutes, each taking a token from the reload bucket (`ReloadBucket`,
/// one every 36 minutes, at most 6 saved), which paces them over the day
/// and the night alike: 40 a day steadily, at most 47 in any 24 hours (a
/// full bucket, a day of refills, and one token a press may borrow).
/// `dailyCap` is that 47, a backstop that never binds while the bucket is
/// kept (a bucket lost with an unsaved state starts full again). Presses of
/// the refresh button are not decided here; the agent's completion reload
/// for a slow press takes a token (or borrows one) and counts toward the
/// same cap. With the widget's own fallback (8 a day) the worst day is 55.
///
/// Ages are measured with `SchedulerClock`: a wall clock jump neither wipes
/// the history nor fakes elapsed time, and a request dated in the future
/// counts as just made rather than being dropped.
public enum ReloadScheduler {
    /// Urgent and ordinary changes alike wait this long after the last request.
    public static let spacing: TimeInterval = 10 * 60
    /// The most the bucket can give in 24 hours: a full bucket, a day of
    /// refills, and the one token a press may borrow. A lower count would
    /// cut in at the end of a busy day and starve the night, as the fixed
    /// count of 40 did.
    public static let dailyCap = Int(ReloadBucket.capacity) + Int(capWindow / ReloadBucket.refill)
        + Int(ReloadBucket.maxDebt)
    /// While the scheduler's memory cannot be saved, every class waits this long.
    public static let conservativeSpacing: TimeInterval = 60 * 60

    /// A press's reasons: what changed since the widget was last asked,
    /// and the press itself.
    public static func pressReasons(_ state: ReloadState, current: DisplayFingerprint, clock: SchedulerClock)
        -> [ReloadReason] {
        let changes = ReloadGate.reasons(from: state.requested, to: current, now: clock.wall)
        return ReloadReason.allCases.filter { changes.contains($0) || $0 == .user }
    }

    /// The earliest moment an ordinary change could be requested.
    public static func nextOrdinary(_ state: ReloadState, clock: SchedulerClock, conservative: Bool) -> Date {
        var ready = clock.wall
        if let last = state.lastRequest {
            let spacing = conservative ? conservativeSpacing : Self.spacing
            ready = max(ready, clock.wall.addingTimeInterval(max(0, spacing - clock.seconds(since: last))))
        }
        // At or over the cap (it may just have fallen), enough requests must
        // leave the day to bring the count under it: count - cap + 1 of the
        // oldest, so the next one can go when the last of those expires.
        let ages = state.requests.map { clock.seconds(since: $0) }.filter { $0 < capWindow }.sorted(by: >)
        if ages.count >= dailyCap {
            let age = ages[ages.count - dailyCap]
            ready = max(ready, clock.wall.addingTimeInterval(capWindow - age))
        }
        if ReloadBucket.tokens(state, at: clock) < 1 - ReloadBucket.slack,
           let token = ReloadBucket.nextToken(state, at: clock) {
            ready = max(ready, token)
        }
        return ready
    }
    public static let capWindow: TimeInterval = 24 * 3600

    /// - Parameter conservative: the scheduler's memory cannot be saved, so
    ///   every class waits `conservativeSpacing` since the last request.
    public static func decide(_ state: ReloadState, current: DisplayFingerprint, clock: SchedulerClock,
                              conservative: Bool = false)
        -> (decision: ReloadDecision, state: ReloadState)
    {
        var next = state
        next.requests = state.requests.filter { clock.seconds(since: $0) < capWindow }

        let changes = ReloadGate.reasons(from: state.requested, to: current, now: clock.wall)
        let reasons = changes
        guard !reasons.isEmpty else {
            next.pending = false
            next.pendingSince = nil
            return (ReloadDecision(fire: false, reasons: [], urgent: false, hold: nil), next)
        }

        let urgent = reasons.contains(where: \.isUrgent)
        let spacing = conservative ? conservativeSpacing : Self.spacing
        let spaced = state.lastRequest.map { clock.seconds(since: $0) >= spacing } ?? true
        let underCap = next.requests.count < dailyCap
        let hasToken = ReloadBucket.tokens(next, at: clock) >= 1 - ReloadBucket.slack

        guard spaced, underCap, hasToken else {
            next.pending = true
            next.pendingSince = state.pending ? (state.pendingSince ?? clock.wall) : clock.wall
            let hold: ReloadDecision.Hold = !underCap ? .cap : (!spaced ? .spacing : .tokens)
            return (ReloadDecision(fire: false, reasons: reasons, urgent: urgent, hold: hold), next)
        }

        ReloadBucket.spend(&next, at: clock)
        next.lastRequest = clock
        next.requested = current
        next.requests.append(clock)
        next.pending = false
        next.pendingSince = nil
        let id = next.takeRequestId()
        return (ReloadDecision(fire: true, reasons: reasons, urgent: urgent, hold: nil, id: id), next)
    }
}

extension ReloadState {
    /// Numbers the next request, background or press.
    public mutating func takeRequestId() -> Int {
        let id = (lastRequestId ?? 0) &+ 1
        lastRequestId = id > 0 ? id : 1
        return lastRequestId ?? 1
    }
}

public enum ReloadStateStore {
    public static let fileName = "reload-state.json"

    public enum ReadResult: Equatable, Sendable {
        /// No file, or one from an older build: start fresh.
        case missing
        case loaded(ReloadState)
        /// The file exists but cannot be read.
        case unreadable(String)
    }

    public static func read(from url: URL) -> ReadResult {
        let data: Data
        switch SafeFile.read(url) {
        case .data(let contents): data = contents
        case .missing: return .missing
        case .refused(let reason): return .unreadable(Redactor.redactEmails(reason))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable("not a reload state file")
        }
        switch object["version"] {
        case nil:
            return migrateVersionOne(object).map(ReadResult.loaded) ?? .unreadable("not a reload state file")
        case let version as Int where version == ReloadState.currentVersion:
            guard let state = try? decoder.decode(ReloadState.self, from: data) else {
                return .unreadable("not a reload state file")
            }
            return .loaded(state)
        default:
            return .unreadable("a reload state file from another build")
        }
    }

    /// The first build stored bare wall times. They become entries with no
    /// boot id, so they are aged by the wall clock and still count against
    /// the daily cap. Its fingerprint is dropped: it lacks the measurement
    /// times the aging rule needs, so it would block every aging reload.
    /// With no fingerprint the next poll counts as a change and goes
    /// through the normal spacing and cap.
    static func migrateVersionOne(_ object: [String: Any]) -> ReloadState? {
        guard let requests = object["requests"] as? [Double] else { return nil }
        func stamp(_ seconds: Double) -> SchedulerClock {
            SchedulerClock(wall: Date(timeIntervalSince1970: seconds), continuous: 0, boot: nil)
        }
        return ReloadState(
            lastRequest: (object["lastRequestAt"] as? Double).map(stamp),
            requests: requests.map(stamp)
        )
    }

    public static func write(_ state: ReloadState, to url: URL) throws {
        try AtomicFile.write(try encoder.encode(state), to: url)
    }

    // Dates as plain seconds: this file is the scheduler's memory, not a
    // format anyone reads.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }
}

/// Paces background reloads: a bucket of at most `capacity` tokens, one
/// more every `refill` (40 a day). Every background reload (ordinary,
/// urgent, or a slow press's completion) takes one; with none, it waits.
/// A busy afternoon spends the saved tokens and then one every 36 minutes,
/// so the night still gets reloads; under a fixed daily count it would
/// spend them all by evening and leave the night with none.
///
/// A press's completion reload may borrow: it may take the bucket one
/// token into debt (never more), so a press that worked always redraws;
/// the next refill repays it. Background reloads never borrow.
///
/// Refill is measured with `SchedulerClock`: a wall clock change neither
/// hands out nor takes away tokens. A state without a bucket (new, or from
/// an older build) starts full.
public enum ReloadBucket {
    public static let capacity: Double = 6
    public static let refill: TimeInterval = 36 * 60
    /// At most this many tokens owed, by a press's completion reload.
    public static let maxDebt: Double = 1
    /// Rounding slack, so a bucket refilled to exactly one token has one.
    static let slack = 1e-9

    public static func tokens(_ state: ReloadState, at clock: SchedulerClock) -> Double {
        guard let saved = state.bucketTokens, saved.isFinite, let at = state.bucketAt else { return capacity }
        return min(capacity, max(-maxDebt, saved) + clock.seconds(since: at) / refill)
    }

    /// Takes a token when there is one. With `mayBorrow` (a press's
    /// completion reload) an empty bucket lends one, unless a debt is
    /// still owed.
    @discardableResult
    public static func spend(_ state: inout ReloadState, at clock: SchedulerClock, mayBorrow: Bool = false) -> Bool {
        let now = tokens(state, at: clock)
        guard now >= (mayBorrow ? 1 - maxDebt : 1) - slack else { return false }
        state.bucketTokens = max(-maxDebt, now - 1)
        state.bucketAt = clock
        return true
    }

    /// When the next usable token arrives (a debt is repaid first); nil
    /// when the bucket is full.
    public static func nextToken(_ state: ReloadState, at clock: SchedulerClock) -> Date? {
        let now = tokens(state, at: clock)
        guard now < capacity - slack else { return nil }
        let target = now < 1 - slack ? 1 : floor(now + slack) + 1
        return clock.wall.addingTimeInterval((target - now) * refill)
    }

    /// What the status window shows.
    public struct Status: Equatable, Sendable {
        /// Whole tokens in the bucket now.
        public var available: Int
        /// When the next one arrives; nil when the bucket is full.
        public var nextRefill: Date?
    }

    public static func status(_ state: ReloadState, at clock: SchedulerClock) -> Status {
        Status(available: max(0, Int(floor(tokens(state, at: clock) + slack))), nextRefill: nextToken(state, at: clock))
    }
}
