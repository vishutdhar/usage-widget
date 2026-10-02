import Foundation

/// One reading of Codex usage, from a rollout file or the app-server.
public struct CodexReading: Equatable, Sendable {
    public enum Source: String, Sendable {
        case rollout
        case appServer = "app-server"
    }

    public var source: Source
    /// The rollout event's timestamp, or when the app-server answered.
    public var measuredAt: Date
    /// Classified by window length, shortest first.
    public var windows: [UsageWindow]
    public var planType: String?
    public var limitId: String?
    /// Banked rate limit resets; only the app-server reports these.
    public var resetCreditsAvailable: Int?
    /// For a reading kept between polls: its age measured on the continuous
    /// clock, which freshness uses in place of the wall clock.
    public var observedAge: TimeInterval?

    public init(source: Source, measuredAt: Date, windows: [UsageWindow], planType: String? = nil,
                limitId: String? = nil, resetCreditsAvailable: Int? = nil) {
        self.source = source
        self.measuredAt = measuredAt
        self.windows = windows
        self.planType = planType
        self.limitId = limitId
        self.resetCreditsAvailable = resetCreditsAvailable
    }
}

/// Codex windows are classified by their length, never by whether they
/// arrive as "primary" or "secondary": the Pro plan reports its weekly
/// window as primary with no secondary.
public enum CodexWindowClassifier {
    /// Up to this long is a session window ("5h").
    public static let sessionMaxMinutes = 6 * 60
    /// From this long is a weekly window ("Weekly").
    public static let weeklyMinMinutes = 24 * 60

    public static func window(usedPercent: Any?, windowMinutes: Any?, resetsAtEpoch: Any?) -> UsageWindow? {
        guard let minutes = CswapListMapper.finite(windowMinutes), minutes > 0, minutes < 1e7 else { return nil }
        let wholeMinutes = Int(minutes)
        let weekly = wholeMinutes >= weeklyMinMinutes
        let reset = CswapListMapper.finite(resetsAtEpoch).flatMap { $0 > 0 && $0 < 1e11 ? Date(timeIntervalSince1970: $0) : nil }
        return UsageWindow(
            kind: weekly ? .weekly : .session,
            name: weekly ? "Weekly" : WindowLength.shortName(seconds: wholeMinutes * 60),
            windowSeconds: wholeMinutes * 60,
            usedPct: CswapListMapper.percent(usedPercent),
            resetsAt: reset
        )
    }

    /// Both windows of a rate limit snapshot, shortest first.
    static func windows(_ raws: [Any?], percentKey: String, minutesKey: String, resetKey: String) -> [UsageWindow] {
        raws.compactMap { raw -> UsageWindow? in
            guard let raw = raw as? [String: Any] else { return nil }
            return window(usedPercent: raw[percentKey], windowMinutes: raw[minutesKey], resetsAtEpoch: raw[resetKey])
        }
        .sorted { $0.windowSeconds < $1.windowSeconds }
    }
}

public enum CodexRolloutParser {
    /// An event dated further ahead of now than this is invalid. Real
    /// rollouts are never dated ahead; during clock skew the app-server and
    /// the last good reading cover.
    public static let futureAllowance: TimeInterval = 120

    /// The last valid event in `data` (JSON lines) carrying rate limits
    /// with a usable window.
    public static func lastReading(in data: Data, now: Date) -> CodexReading? {
        scan(data, now: now).reading
    }

    /// The last valid reading, and whether any later event was skipped for
    /// being dated ahead.
    public static func scan(_ data: Data, now: Date) -> (reading: CodexReading?, skippedFuture: Bool) {
        var skippedFuture = false
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = event["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any],
                  let stamp = (event["timestamp"] as? String).flatMap(ISODate.parse)
            else { continue }
            let windows = CodexWindowClassifier.windows([limits["primary"], limits["secondary"]], percentKey: "used_percent",
                                                        minutesKey: "window_minutes", resetKey: "resets_at")
            // An event without a usable window is not a reading; look further back.
            guard !windows.isEmpty else { continue }
            // Nor is one dated ahead of now.
            guard stamp.timeIntervalSince(now) <= futureAllowance else {
                skippedFuture = true
                continue
            }
            let reading = CodexReading(
                source: .rollout,
                measuredAt: stamp,
                windows: windows,
                planType: limits["plan_type"] as? String,
                limitId: limits["limit_id"] as? String
            )
            return (reading, skippedFuture)
        }
        return (nil, skippedFuture)
    }
}

public enum CodexAppServerParser {
    /// The `result` of an `account/rateLimits/read` reply.
    public static func reading(fromResult result: [String: Any], fetchedAt: Date) -> CodexReading? {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        let windows = CodexWindowClassifier.windows([limits["primary"], limits["secondary"]], percentKey: "usedPercent",
                                                    minutesKey: "windowDurationMins", resetKey: "resetsAt")
        // A reply without a usable window is not a reading: it must not wipe
        // the last good numbers.
        guard !windows.isEmpty else { return nil }
        let credits = (result["rateLimitResetCredits"] as? [String: Any]).flatMap { CswapListMapper.finite($0["availableCount"]) }
        return CodexReading(
            source: .appServer,
            measuredAt: fetchedAt,
            windows: windows,
            planType: limits["planType"] as? String,
            limitId: limits["limitId"] as? String,
            resetCreditsAvailable: credits.flatMap { $0 >= 0 && $0 < 1e6 ? Int($0) : nil }
        )
    }
}

/// Builds the snapshot's `codex` provider block.
public enum CodexMerge {
    public static let provider = "codex"
    public static let appServerCheckedAtKey = "appServerCheckedAt"
    /// A newest reading older than this marks the account stale.
    public static let staleAfter: TimeInterval = Staleness.line(for: provider)

    /// The reading measured last. On a tie the app-server's answer wins,
    /// then the rollout, then the last known reading.
    public static func newest(rollout: CodexReading?, appServer: CodexReading?, lastKnown: CodexReading?) -> CodexReading? {
        var best: CodexReading?
        for candidate in [appServer, rollout, lastKnown].compactMap({ $0 }) where best.map({ candidate.measuredAt > $0.measuredAt }) ?? true {
            best = candidate
        }
        return best
    }

    /// The banked reset count: only ever from an app-server answer, the
    /// live one first, else the one kept in the last known reading.
    public static func resetCredits(appServer: CodexReading?, lastKnown: CodexReading?) -> Int? {
        appServer?.resetCreditsAvailable ?? lastKnown?.resetCreditsAvailable
    }

    /// - Parameters:
    ///   - rollout: the newest rollout reading, if any.
    ///   - appServer: the last successful app-server reading, if any.
    ///   - lastKnown: what the block showed last (after a restart, read
    ///     back from the snapshot), with its reset count.
    ///   - appServerError: why the latest app-server call failed, if it did.
    ///   - codexFound: whether a codex binary or rollout files exist at all.
    ///
    /// A failed app-server call is not a change in usage: while any reading
    /// is fresh the block stays ok and the reason goes to `collectorError`.
    /// Only without a fresh reading does the failure become the status.
    public static func block(rollout: CodexReading?, appServer: CodexReading?, lastKnown: CodexReading? = nil,
                             appServerCheckedAt: Date? = nil,
                             appServerError: String?, codexFound: Bool, now: Date) -> ProviderUsage {
        let newest = newest(rollout: rollout, appServer: appServer, lastKnown: lastKnown)
        let fresh = newest.map { ($0.observedAge ?? now.timeIntervalSince($0.measuredAt)) <= staleAfter } ?? false
        let account: AccountUsage
        if let newest {
            var kept = AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: newest.measuredAt,
                                    windows: newest.windows, status: fresh ? .ok : .stale,
                                    statusNote: fresh ? nil : "No new reading")
            // The age on the continuous clock, so the widget judges staleness by it
            // rather than by the wall clock.
            kept.ageSeconds = newest.observedAge
            account = kept
        } else {
            account = AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: nil, windows: [],
                                   status: .unavailable,
                                   statusNote: codexFound ? "Usage unavailable" : "Codex not found")
        }
        let plan = newest?.planType ?? appServer?.planType ?? rollout?.planType ?? lastKnown?.planType
        let credits = resetCredits(appServer: appServer, lastKnown: lastKnown)
        let reason = appServerError.map(Redactor.redactEmails)
        let failing = reason != nil && !fresh
        return ProviderUsage(
            provider: provider,
            source: (newest?.source ?? .rollout).rawValue,
            status: failing ? .error : .ok,
            error: failing ? reason : nil,
            accounts: [account],
            extras: [
                "resetCreditsAvailable": credits.map { .number(Double($0)) } ?? .null,
                "planType": plan.map { .string($0) } ?? .null,
                // When the app-server last answered, whichever source won the
                // windows: a restart seeds its daily ceiling from this.
                appServerCheckedAtKey: appServerCheckedAt.map { .string(ISODate.format($0)) } ?? .null,
            ],
            collectorError: reason
        )
    }
}
