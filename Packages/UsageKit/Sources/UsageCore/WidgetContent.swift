import Foundation

/// Everything a widget view needs, computed from a snapshot at one moment.
public struct WidgetContent: Equatable, Sendable {
    /// The agent has stopped writing: the footer says the widget is not
    /// updating.
    public var notUpdating = false

    public struct Account: Equatable, Sendable, Identifiable {
        public var id: String
        public var label: String
        public var active: Bool
        public var rows: [WindowRow]
        /// What is wrong, in secondary text: the account's status note, or
        /// "Usage unavailable" when there are no numbers.
        public var note: String?
        /// When the last known numbers were measured, for an account that is
        /// not current but still has numbers to show.
        public var lastKnownAt: Date?
        /// The numbers are past their provider's stale line at this entry's
        /// date. Data only: bars keep their colours whatever their age.
        public var dimmed: Bool
        /// Set when the numbers are past their provider's line at this
        /// entry's date: when they were measured, for the "stale" line.
        public var staleSince: Date?
        /// When the numbers shown were measured.
        public var measuredAt: Date?
        /// The numbers are current (status ok), so they count toward "as of".
        public var current: Bool
        /// Shown beside the label: the provider's plan ("Pro").
        public var detail: String?
        /// Shown under the rows: "2 resets available".
        public var footnote: String?

        public init(id: String, label: String, active: Bool, rows: [WindowRow], note: String?,
                    lastKnownAt: Date? = nil, dimmed: Bool = false, measuredAt: Date? = nil, current: Bool = true,
                    detail: String? = nil, footnote: String? = nil) {
            self.id = id
            self.label = label
            self.active = active
            self.rows = rows
            self.note = note
            self.lastKnownAt = lastKnownAt
            self.dimmed = dimmed
            self.measuredAt = measuredAt
            self.current = current
            self.detail = detail
            self.footnote = footnote
        }

        /// At most `limit` rows: the 5h window, the 7d window and the most
        /// used model window, in display order, topped up from the rest when
        /// there are fewer. `hidden` counts the rows left out.
        /// Current numbers past their line, with no note of their own: the
        /// account says "stale" with their time.
        public var hasStaleLine: Bool { staleSince != nil && note == nil }

        /// The rows `compactRows(limit:)` leaves out, in their own order.
        public func omittedRows(limit: Int) -> [WindowRow] {
            let kept = compactRows(limit: limit).rows
            var remaining = kept
            return rows.filter { row in
                if let i = remaining.firstIndex(of: row) {
                    remaining.remove(at: i)
                    return false
                }
                return true
            }
        }

        public func compactRows(limit: Int) -> (rows: [WindowRow], hidden: Int) {
            guard rows.count > limit else { return (rows, 0) }
            // Picked by importance, drawn in their own order: the weekly
            // window and the busiest model say how much of the week is left,
            // then the 5 hour window, then the rest in order.
            var ranked: [Int] = []
            if let i = rows.firstIndex(where: { $0.kind == .weekly }) { ranked.append(i) }
            let models = rows.indices.filter { rows[$0].kind == .model }
            // The busiest model; an unknown value never outranks a known one.
            if let i = models.max(by: { (rows[$0].level == .unknown ? -1 : rows[$0].usedPct)
                                            < (rows[$1].level == .unknown ? -1 : rows[$1].usedPct) }) {
                ranked.append(i)
            }
            if let i = rows.firstIndex(where: { $0.kind == .session }) { ranked.append(i) }
            ranked += rows.indices.filter { !ranked.contains($0) }
            let picked = Set(ranked.prefix(limit))
            let kept = rows.indices.filter(picked.contains).map { rows[$0] }
            return (Array(kept), rows.count - kept.count)
        }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var id: String { provider }
        public var provider: String
        /// Shown only when more than one provider is on screen.
        public var title: String
        /// The provider's error reason, drawn above its last known data.
        public var errorText: String?
        /// In the provider's own order (cswap slot order).
        public var accounts: [Account]

        public init(provider: String, title: String, errorText: String?, accounts: [Account]) {
            self.provider = provider
            self.title = title
            self.errorText = errorText
            self.accounts = accounts
        }

        /// The active account first, then the rest in order.
        public var accountsActiveFirst: [Account] {
            accounts.filter(\.active) + accounts.filter { !$0.active }
        }
    }

    /// False until the agent has written a first snapshot.
    public var hasSnapshot: Bool
    public var sections: [Section]
    /// The entry's date.
    public var date: Date
    /// When the agent wrote the snapshot; nil without one.
    public var writtenAt: Date?
    /// What the footer says about a press of the refresh button.
    public var refreshFooter: RefreshFooter = .none
    public var refreshing: Bool { refreshFooter == .refreshing }

    public init(hasSnapshot: Bool, sections: [Section], date: Date) {
        self.hasSnapshot = hasSnapshot
        self.sections = sections
        self.date = date
    }

    /// The account the medium widget draws in full: the active one, or the
    /// first when none is active.
    public var featured: Account? {
        let all = sections.flatMap(\.accounts)
        return all.first(where: \.active) ?? all.first
    }

    /// Every account in the order space is given to it: the featured
    /// account, then the other providers' accounts (Codex beside Claude),
    /// then the featured provider's remaining accounts in slot order.
    public var accountsByPriority: [Account] {
        guard let featured else { return [] }
        let rest = (homeSection?.accounts ?? []).filter { $0 != featured }
        return [featured] + otherProviderAccounts + rest
    }

    /// The featured account's provider.
    public var homeSection: Section? {
        featured.flatMap { featured in sections.first { $0.accounts.contains(featured) } }
    }

    /// Accounts of every provider but the featured one's (Codex beside
    /// Claude). Layouts never leave these out.
    public var otherProviderAccounts: [Account] {
        guard let home = homeSection else { return [] }
        return sections.filter { $0.provider != home.provider }.flatMap(\.accounts)
    }

    /// The accounts no layout leaves out: the featured one and the other
    /// providers'.
    public var pinnedCount: Int {
        featured == nil ? 0 : 1 + otherProviderAccounts.count
    }

    /// When the oldest current, not stale numbers among `accounts` were
    /// measured: the widget passes the accounts its layout actually shows
    /// and prints "as of" this time, which is then true of every number it
    /// speaks for and never newer than any of them. A stale account carries
    /// its own "stale · as of" line and is left out; with only stale ones
    /// shown, their oldest time.
    public static func asOf(of accounts: [Account]) -> Date? {
        let current = accounts.filter { $0.current && !$0.rows.isEmpty }
        let fresh = current.filter { $0.staleSince == nil }
        return (fresh.isEmpty ? current : fresh).compactMap(\.measuredAt).min()
    }

    /// The footer's time for the accounts a layout shows (`asOf(of:)`), or,
    /// with no measurement among them, when the agent last wrote the snapshot.
    public func footerTime(for shown: [Account]) -> Date? {
        Self.asOf(of: shown) ?? writtenAt
    }

    public static let unavailableNote = "Usage unavailable"

    /// - Parameter date: the moment the entry is shown. Resets that have
    ///   passed by then are rolled forward, and each account ages from its
    ///   own measurement time, so a future entry is as old as it will look.
    /// - Parameter checkedAt: when the widget read the snapshot; one already
    ///   more than `agentSilence` old then means the agent is not running.
    public static func make(snapshot: UsageSnapshot?, at date: Date, refresh: RefreshRequest?,
                            checkedAt: Date) -> WidgetContent {
        var content = make(snapshot: snapshot, at: date, refresh: refresh)
        if let snapshot { content.notUpdating = checkedAt.timeIntervalSince(snapshot.writtenAt) > agentSilence }
        return content
    }

    /// The agent rewrites the snapshot every minute; one older than this
    /// when the widget reads it means the agent is not running.
    public static let agentSilence: TimeInterval = 5 * 60

    public static func make(snapshot: UsageSnapshot?, at date: Date, refresh: RefreshRequest?) -> WidgetContent {
        var content = make(snapshot: snapshot, at: date)
        content.refreshFooter = RefreshState.footer(request: refresh, snapshot: snapshot?.mark, at: date)
        return content
    }

    public static func make(snapshot: UsageSnapshot?, at date: Date) -> WidgetContent {
        guard let snapshot else { return WidgetContent(hasSnapshot: false, sections: [], date: date) }
        let sections = snapshot.providers.filter { !$0.hidden }.map { provider in
            Section(
                provider: provider.provider,
                title: title(forProvider: provider.provider),
                errorText: provider.displayedError,
                accounts: provider.accounts.map { account in
                    var shown = self.account(from: account, at: date, provider: provider.provider,
                                             writtenAt: snapshot.writtenAt)
                    shown.detail = ProviderDetails.plan(in: provider.extras)
                    shown.footnote = ProviderDetails.footnote(in: provider.extras)
                    return shown
                }
            )
        }
        var content = WidgetContent(hasSnapshot: true, sections: sections, date: date)
        content.writtenAt = snapshot.writtenAt
        return content
    }

    static func account(from account: AccountUsage, at date: Date, provider: String, writtenAt: Date? = nil) -> Account {
        let rows = account.windows.map { UsageDisplay.row(for: $0, at: date) }
        let note: String? = account.status == .ok
            ? (rows.isEmpty ? unavailableNote : nil)
            : (account.statusNote ?? unavailableNote)
        let lastKnown = account.status != .ok && !rows.isEmpty ? account.fetchedAt : nil
        let dimmed = !rows.isEmpty && Staleness.isDimmed(account, writtenAt: writtenAt, at: date, provider: provider)
        var shown = Account(id: account.id, label: account.label, active: account.active, rows: rows,
                            note: note, lastKnownAt: lastKnown, dimmed: dimmed,
                            measuredAt: account.fetchedAt, current: account.status == .ok)
        // Current numbers past their line say so in words; the bars keep
        // their usage colours.
        if dimmed, account.status == .ok { shown.staleSince = account.fetchedAt }
        return shown
    }

    public static func title(forProvider provider: String) -> String {
        switch provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        default: return provider.prefix(1).uppercased() + provider.dropFirst()
        }
    }
}

extension WidgetContent {
    /// One timeline entry: its date and what it shows.
    public struct TimelineEntry {
        public let date: Date
        public let content: WidgetContent
    }

    /// The entries for a read of the snapshot at `readAt` (the plan's
    /// dates unless given). Whether the agent stopped is judged at the
    /// read, never at an entry's date: between reads WidgetKit shows these
    /// entries, and a healthy agent asks for a read only when the display
    /// changes, so an entry's age says nothing about the agent. A stopped
    /// agent shows at the next read, which the plan's fallback brings
    /// within `TimelinePlan.reloadFloor`.
    public static func timelineEntries(for snapshot: UsageSnapshot?, readAt: Date, refresh: RefreshRequest?,
                                       dates: [Date]? = nil) -> [TimelineEntry] {
        let dates = dates ?? TimelinePlan.plan(for: snapshot, now: readAt, refresh: refresh).entries
        return dates.map {
            TimelineEntry(date: $0, content: make(snapshot: snapshot, at: $0, refresh: refresh, checkedAt: readAt))
        }
    }
}
