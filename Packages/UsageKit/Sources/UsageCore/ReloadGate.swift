import Foundation

public enum ReloadReason: String, Codable, Sendable, CaseIterable {
    /// No earlier request to compare against.
    case first
    /// A provider's or an account's status changed.
    case status
    /// The active account changed.
    case active
    /// A provider, account or window appeared or disappeared, or a label changed.
    case layout
    /// A window crossed a colour band (70, 90) or reached 100, or became unknown.
    case band
    /// A reset moved by more than the tolerance, and the old or new time falls
    /// inside the timeline's horizon, so a planned entry is now wrong.
    case resetSoon = "reset"
    /// A whole-number percent the widget shows changed.
    case percent
    /// A pace tick appeared or disappeared.
    case pace
    /// A reset moved by more than the tolerance, but outside the horizon.
    case resetMoved = "reset-moved"
    /// A spend window's amount or limit text changed.
    case spend
    /// The numbers the widget shows will pass the two hour dimming line
    /// within the next poll, and newer numbers exist.
    case aging
    /// A provider detail the widget shows changed: the plan, or the count
    /// of banked resets.
    case details
    /// A provider's error line, as the widget shows it, changed.
    case errorText = "error"
    /// The person pressed the widget's refresh button.
    case user

    /// Every change waits the same 10 minutes; urgency is logged, and marks
    /// what a person would most want to see.
    public var isUrgent: Bool {
        switch self {
        case .first, .status, .active, .layout, .band, .resetSoon: return true
        case .percent, .pace, .resetMoved, .spend, .aging, .details, .errorText, .user: return false
        }
    }
}

/// Everything the widget shows that a reload could change, reduced to
/// comparable values. The scheduler keeps the fingerprint it last asked the
/// widget to show and compares each poll against it.
public struct DisplayFingerprint: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var percent: Int?
        public var level: UsageLevel
        public var pace: Bool
        public var resetsAt: Date?
        /// Spend only: the amount, limit and currency the right column shows.
        public var detail: String?
    }

    public struct Account: Codable, Equatable, Sendable {
        public var label: String
        public var active: Bool
        public var status: AccountUsage.Status
        public var statusNote: String?
        /// Not compared on its own: only the aging rule reads it.
        public var fetchedAt: Date?
        public var windowOrder: [String]
        public var windows: [String: Window]
    }

    public struct Provider: Codable, Equatable, Sendable {
        public var status: ProviderUsage.Status
        public var accountOrder: [String]
        public var accounts: [String: Account]
        /// The plan and reset footnote as shown, nil when there are none
        /// (and in fingerprints saved before they existed).
        public var details: [String]?
        /// The error line as shown, nil when there is none (and in
        /// fingerprints saved before it was recorded).
        public var error: String?
    }

    public var providerOrder: [String]
    public var providers: [String: Provider]

    public init(_ snapshot: UsageSnapshot) {
        let shown = snapshot.providers.filter { !$0.hidden }
        providerOrder = shown.map(\.provider)
        var providers: [String: Provider] = [:]
        for provider in shown {
            var accounts: [String: Account] = [:]
            for account in provider.accounts {
                var windows: [String: Window] = [:]
                for window in account.windows {
                    windows[window.name] = Window(
                        percent: window.usedPct.map(UsageDisplay.displayedPercent),
                        level: window.usedPct.map(UsageThresholds.level(for:)) ?? .unknown,
                        pace: UsageDisplay.paceFraction(for: window) != nil,
                        resetsAt: window.resetsAt,
                        detail: window.kind == .spend
                            ? "\(window.amount.map { "\($0)" } ?? "-") of \(window.limit.map { "\($0)" } ?? "-") \(window.currency ?? "")"
                            : nil
                    )
                }
                accounts[account.id] = Account(
                    label: account.label, active: account.active, status: account.status,
                    statusNote: account.statusNote,
                    fetchedAt: account.fetchedAt,
                    windowOrder: account.windows.map(\.name), windows: windows
                )
            }
            let details = [ProviderDetails.plan(in: provider.extras), ProviderDetails.footnote(in: provider.extras)]
                .map { $0 ?? "" }
            providers[provider.provider] = Provider(
                status: provider.status, accountOrder: provider.accounts.map(\.id), accounts: accounts,
                details: details.allSatisfy(\.isEmpty) ? nil : details,
                error: provider.displayedError
            )
        }
        self.providers = providers
    }
}

/// Classifies what changed between two fingerprints.
public enum ReloadGate {
    /// Reset times that move less than this are jitter, not news.
    public static let resetTolerance: TimeInterval = 5 * 60

    /// Empty when nothing visible changed.
    public static func reasons(from old: DisplayFingerprint?, to new: DisplayFingerprint, now: Date) -> [ReloadReason] {
        guard let old else { return [.first] }
        var found = Set<ReloadReason>()
        if old.providerOrder != new.providerOrder { found.insert(.layout) }
        for (id, after) in new.providers {
            guard let before = old.providers[id] else { continue }
            if before.status != after.status { found.insert(.status) }
            if before.accountOrder != after.accountOrder { found.insert(.layout) }
            if before.details != after.details { found.insert(.details) }
            if before.error != after.error { found.insert(.errorText) }
            let activeBefore = Set(before.accounts.filter { $0.value.active }.keys)
            let activeAfter = Set(after.accounts.filter { $0.value.active }.keys)
            if activeBefore != activeAfter { found.insert(.active) }
            for (accountID, a) in after.accounts {
                guard let b = before.accounts[accountID] else { continue }
                if b.status != a.status || b.statusNote != a.statusNote { found.insert(.status) }
                if b.label != a.label || b.windowOrder != a.windowOrder { found.insert(.layout) }
                if aging(shown: b.fetchedAt, available: a.fetchedAt, now: now, line: Staleness.line(for: id)) {
                    found.insert(.aging)
                }
                for (name, w) in a.windows {
                    guard let v = b.windows[name] else { continue }
                    if v.level != w.level { found.insert(.band) }
                    if v.percent != w.percent { found.insert(.percent) }
                    if v.pace != w.pace { found.insert(.pace) }
                    if v.detail != w.detail { found.insert(.spend) }
                    if let reset = resetChange(from: v.resetsAt, to: w.resetsAt, now: now) { found.insert(reset) }
                }
            }
        }
        return ReloadReason.allCases.filter(found.contains)
    }

    /// How often the agent polls: the aging rule looks this far ahead.
    public static let pollInterval: TimeInterval = 60

    /// The shown numbers pass the dimming line before the next poll, and
    /// newer numbers exist to replace them. When the shown measurement time
    /// is unknown (a fingerprint from a build that did not record it), the
    /// widget may already be dimming the account, so any numbers still
    /// short of the line are worth one ordinary reload.
    static func aging(shown: Date?, available: Date?, now: Date, line: TimeInterval = Staleness.dimAfter) -> Bool {
        guard let available else { return false }
        guard let shown else { return !(now.timeIntervalSince(available) > line) }
        guard available > shown else { return false }
        return shown.addingTimeInterval(line) <= now.addingTimeInterval(pollInterval)
    }

    /// A reset time change bigger than the tolerance, urgent when the old or
    /// the new time is still ahead and inside the timeline horizon.
    static func resetChange(from old: Date?, to new: Date?, now: Date) -> ReloadReason? {
        switch (old, new) {
        case (nil, nil):
            return nil
        case let (o?, n?) where abs(o.timeIntervalSince(n)) <= resetTolerance:
            return nil
        default:
            let horizonEnd = now.addingTimeInterval(TimelinePlan.horizon)
            let planned = [old, new].compactMap { $0 }.contains { $0 > now && $0 <= horizonEnd }
            if planned { return .resetSoon }
            // A reset that already passed and then disappears was handled by
            // the entry planned for it.
            let upcoming = [old, new].compactMap { $0 }.contains { $0 > now }
            return upcoming ? .resetMoved : nil
        }
    }

    public static func reasons(from old: UsageSnapshot?, to new: UsageSnapshot, now: Date) -> [ReloadReason] {
        reasons(from: old.map(DisplayFingerprint.init), to: DisplayFingerprint(new), now: now)
    }
}
