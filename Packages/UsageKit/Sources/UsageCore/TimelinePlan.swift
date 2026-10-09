import Foundation

public enum TimelinePlan {
    /// The widget's own fallback reload. Every agent request replaces the
    /// timeline, so this fires only when the agent has gone quiet. At most
    /// 8 a day, which with the agent's 40 makes a worst day of 48, inside
    /// WidgetKit's 40 to 70.
    public static let reloadFloor: TimeInterval = 3 * 3600
    /// How far ahead reset entries are planned.
    public static let horizon: TimeInterval = 24 * 3600
    /// Resets are grouped into buckets this long, each entry at its bucket's end.
    public static let bucket: TimeInterval = 5 * 60
    public static let maxBuckets = 8

    public struct Plan: Equatable, Sendable {
        public var entries: [Date]
        public var reloadAfter: Date
    }

    /// Entries for one timeline: now, then the end of each 5 minute bucket
    /// that holds a reset or the moment an account's numbers pass the two
    /// hour stale line, at most `maxBuckets` of them.
    /// The plan, plus an entry where a pending refresh's "Refreshing…"
    /// runs out, so the footer goes back to "as of" on time.
    public static func plan(for snapshot: UsageSnapshot?, now: Date, refresh: RefreshRequest?) -> Plan {
        var plan = plan(for: snapshot, now: now)
        if RefreshState.footer(request: refresh, snapshot: snapshot, at: now) != .none,
           let refresh {
            let end = refresh.requestedAt.addingTimeInterval(RefreshState.window)
            plan.entries = Array(Set(plan.entries + [end])).sorted()
        }
        return plan
    }

    public static func plan(for snapshot: UsageSnapshot?, now: Date) -> Plan {
        let floor = now.addingTimeInterval(reloadFloor)
        guard let snapshot else { return Plan(entries: [now], reloadAfter: floor) }
        let end = now.addingTimeInterval(horizon)
        let shown = snapshot.providers.filter { !$0.hidden }
        let accounts = shown.flatMap(\.accounts)
        // Each account turns stale at its provider's line.
        let dimMoments = shown.flatMap { provider in
            provider.accounts.filter { !$0.windows.isEmpty }.compactMap {
                Staleness.dimMoment($0, writtenAt: snapshot.writtenAt, provider: provider.provider)
            }
        }

        func buckets(_ moments: [Date]) -> [Date] {
            Set(moments.filter { $0 > now && $0 <= end }.map(bucketEnd)).sorted()
        }
        // Each account's numbers dim two hours after they were measured.
        // Dimming crossings take the slots first, earliest first, up to all
        // eight; reset buckets fill whatever remains.
        let dimming = Array(buckets(dimMoments).prefix(maxBuckets))
        let resets = buckets(accounts.flatMap(\.windows).compactMap(\.resetsAt)).filter { !dimming.contains($0) }

        // Buckets past the eighth wait for the next timeline; shortening the
        // policy for them would break the daily budget.
        let kept = (dimming + resets.prefix(maxBuckets - dimming.count)).sorted()
        return Plan(entries: [now] + kept, reloadAfter: floor)
    }

    /// The end of the 5 minute bucket holding `date` (rounded up), so an
    /// entry never lands before the moment it is for.
    public static func bucketEnd(_ date: Date) -> Date {
        let t = date.timeIntervalSince1970
        guard t.isFinite else { return date }
        return Date(timeIntervalSince1970: (t / bucket).rounded(.up) * bucket)
    }
}
