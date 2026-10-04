import SwiftUI
import UsageCore

public enum UsageWidgetSize: Sendable {
    /// The active account (at most three rows), the others one line each.
    case medium
    /// Every account in full, cut to three rows each only when needed.
    case large
}

/// The whole widget body for one timeline entry. The widget extension adds
/// the container background; this view draws only the content.
///
/// Dates, times and amounts are formatted with the SwiftUI environment's
/// locale, time zone and calendar.
public struct UsageWidgetView: View {
    let content: WidgetContent
    let size: UsageWidgetSize
    let refreshControl: AnyView?

    /// - Parameter refreshControl: drawn at the right of the footer line;
    ///   the widget passes a button driven by its refresh intent.
    public init(content: WidgetContent, size: UsageWidgetSize, refreshControl: AnyView? = nil) {
        self.content = content
        self.size = size
        self.refreshControl = refreshControl
    }

    public var body: some View {
        if !content.hasSnapshot {
            EmptyStateView()
        } else {
            WidgetFrame(content: content, size: size) {
                switch size {
                case .medium: MediumBody(content: content)
                case .large: LargeBody(content: content)
                }
            }
            .refreshControl(refreshControl)
        }
    }

    /// The smallest layout this size falls back to. Tests measure it to
    /// prove that even the fullest account fits, footer control included.
    static func tightestLayout(content: WidgetContent, size: UsageWidgetSize,
                               refreshControl: AnyView? = AnyView(RefreshButtonLabel())) -> some View {
        let count = size == .medium ? MediumLayout.candidates(in: content).count : LargeLayout.candidates(in: content).count
        return candidateLayout(content: content, size: size, index: max(0, count - 1), refreshControl: refreshControl)
    }

    /// One candidate layout of this size, as the widget's ViewThatFits
    /// tries it, footer control included. Tests measure each to find the
    /// one the widget picks.
    static func candidateLayout(content: WidgetContent, size: UsageWidgetSize, index: Int,
                                refreshControl: AnyView? = AnyView(RefreshButtonLabel())) -> some View {
        WidgetFrame(content: content, size: size) {
            switch size {
            case .medium:
                let candidates = MediumLayout.candidates(in: content)
                if candidates.indices.contains(index) {
                    MediumLayout(content: content, candidate: candidates[index])
                }
            case .large:
                let candidates = LargeLayout.candidates(in: content)
                if candidates.indices.contains(index) {
                    LargeLayout(content: content, candidate: candidates[index])
                }
            }
        }
        .refreshControl(refreshControl)
    }
}

/// The circular arrow the refresh button shows.
public struct RefreshButtonLabel: View {
    public init() {}

    public var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 12)  // no taller than the footer text
            // Clickable a little past the arrow, without moving it: a click
            // just beside it would open the app instead.
            .contentShape(Rectangle().inset(by: -6))
            .accessibilityLabel("Refresh")
    }
}

private struct RefreshControlKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: AnyView? = nil
}

extension EnvironmentValues {
    /// The footer's refresh control, set once for the whole widget.
    var refreshControl: AnyView? {
        get { self[RefreshControlKey.self] }
        set { self[RefreshControlKey.self] = newValue }
    }
}

extension View {
    func refreshControl(_ control: AnyView?) -> some View {
        environment(\.refreshControl, control)
    }
}

/// The provider error lines drawn above a layout.
enum ErrorLines {
    /// One line per provider with an error, named when more than one
    /// provider is on screen. The medium widget leaves out the error of a
    /// provider whose accounts get their own compact line (Codex): that line
    /// shows the provider's numbers or note, and the error line would push
    /// it off the widget.
    static func lines(for content: WidgetContent, size: UsageWidgetSize) -> [String] {
        let home = content.featured.flatMap { featured in
            content.sections.first { $0.accounts.contains(featured) }?.provider
        }
        return content.sections.compactMap { section in
            guard let error = section.errorText else { return nil }
            if size == .medium, section.provider != home, !section.accounts.isEmpty { return nil }
            guard content.sections.count > 1 else { return error }
            // "codex app-server did not answer" already names its provider.
            if error.lowercased().hasPrefix(section.title.lowercased() + " ") {
                return error.prefix(1).uppercased() + error.dropFirst()
            }
            return "\(section.title): \(error)"
        }
    }
}

/// Error lines on top, then the body. Each layout draws its own "as of"
/// line, since only it knows which accounts it shows.
private struct WidgetFrame<Body: View>: View {
    let content: WidgetContent
    let size: UsageWidgetSize
    @ViewBuilder let body_: Body

    init(content: WidgetContent, size: UsageWidgetSize, @ViewBuilder body: () -> Body) {
        self.content = content
        self.size = size
        self.body_ = body()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ErrorLines.lines(for: content, size: size), id: \.self) { line in
                Text(verbatim: line)
                    .font(Style.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            body_
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "Open Usage Widget to start": shown until the agent writes a snapshot.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("No usage yet")
                .font(Style.titleActive)
            Text("Open Usage Widget to start")
                .font(Style.label)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
    }
}

/// The active account at most three rows deep, then as many other accounts
/// as fit, one line each. `ViewThatFits` measures the real text, so nothing
/// is clipped whatever the fonts turn out to be.
private struct MediumBody: View {
    let content: WidgetContent

    var body: some View {
        let candidates = MediumLayout.candidates(in: content)
        ViewThatFits(in: .vertical) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                MediumLayout(content: content, candidate: candidate)
            }
        }
    }
}

struct MediumLayout: View {
    let content: WidgetContent
    let visibleOthers: Int
    /// Rows drawn for the featured account before "+N more".
    var featuredRows = 3
    /// The featured account's stale mark in its header, not on a line.
    var staleInHeader = false

    struct Candidate: Equatable {
        var visibleOthers: Int
        var featuredRows: Int
        var staleInHeader = false
    }

    init(content: WidgetContent, visibleOthers: Int, featuredRows: Int = 3, staleInHeader: Bool = false) {
        // Accounts older than this layout's footer say so on their own line.
        self.content = content.markingOwnTimes(footer: Self.asOf(in: content, visibleOthers: visibleOthers))
        self.visibleOthers = visibleOthers
        self.featuredRows = featuredRows
        self.staleInHeader = staleInHeader
    }

    init(content: WidgetContent, candidate: Candidate) {
        self.init(content: content, visibleOthers: candidate.visibleOthers, featuredRows: candidate.featuredRows,
                  staleInHeader: candidate.staleInHeader)
    }

    /// The layouts to try: every other account, first with the featured
    /// account's stale line and then with it moved into its header; then
    /// fewer other accounts, never below the other providers' lines
    /// (Codex); then, only if that still does not fit, the featured
    /// account cut to two rows and then one.
    static func candidates(in content: WidgetContent) -> [Candidate] {
        let fewest = fewestOthers(in: content)
        let stale = featured(in: content)?.hasStaleLine ?? false
        var list: [Candidate] = []
        for visible in (fewest...others(in: content).count).reversed() {
            if list.isEmpty || !stale { list.append(Candidate(visibleOthers: visible, featuredRows: 3)) }
            if stale { list.append(Candidate(visibleOthers: visible, featuredRows: 3, staleInHeader: true)) }
        }
        if fewest > 0 {
            list += [Candidate(visibleOthers: fewest, featuredRows: 2, staleInHeader: stale),
                     Candidate(visibleOthers: fewest, featuredRows: 1, staleInHeader: stale)]
        }
        return list
    }

    static func featured(in content: WidgetContent) -> WidgetContent.Account? {
        content.featured
    }

    /// The accounts this layout draws.
    static func shown(in content: WidgetContent, visibleOthers: Int) -> [WidgetContent.Account] {
        (featured(in: content).map { [$0] } ?? []) + others(in: content).prefix(visibleOthers)
    }

    static func asOf(in content: WidgetContent, visibleOthers: Int) -> Date? {
        content.footerTime(for: shown(in: content, visibleOthers: visibleOthers))
    }

    /// Codex's line comes right after the featured account, then the
    /// other Claude accounts.
    static func others(in content: WidgetContent) -> [WidgetContent.Account] {
        Array(content.accountsByPriority.dropFirst())
    }

    /// Other lines never left out: the other providers' (the Codex line).
    static func fewestOthers(in content: WidgetContent) -> Int {
        content.otherProviderAccounts.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            grid
            Spacer(minLength: 4)  // the as of line sits at the bottom
            AsOfLine(date: Self.asOf(in: content, visibleOthers: visibleOthers), now: content.date, footer: content.refreshFooter,
                     notUpdating: content.notUpdating)
        }
    }

    private var grid: some View {
        let featured = Self.featured(in: content)
        let others = Self.others(in: content)
        return Grid(alignment: .leading, horizontalSpacing: Style.columnSpacing, verticalSpacing: Style.rowSpacing) {
            if let featured {
                AccountBlock(account: featured, now: content.date, rowLimit: featuredRows,
                             reservesMarker: featured.compactRows(limit: featuredRows).rows.contains(where: \.overMarker),
                             staleInHeader: staleInHeader)
            } else {
                NoAccountsRow()
            }
            if !others.isEmpty {
                Color.clear.frame(height: 2).gridCellUnsizedAxes(.horizontal)
            }
            ForEach(Array(others.prefix(visibleOthers).enumerated()), id: \.offset) { _, account in
                CompactAccountRow(account: account, now: content.date)
            }
            if visibleOthers < others.count {
                MoreRow(count: others.count - visibleOthers)
            }
        }
    }
}

/// Every account in full, in slot order, with Codex below the Claude
/// accounts. When that does not fit, the spacing tightens to the medium
/// widget's, then stale lines move into the account headers, then each
/// account is cut to three rows and then two (weekly and the busiest
/// model), and only then are Claude accounts left out from the end of the
/// list, never the active one and never Codex.
private struct LargeBody: View {
    let content: WidgetContent

    var body: some View {
        let candidates = LargeLayout.candidates(in: content)
        ViewThatFits(in: .vertical) {
            ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                LargeLayout(content: content, candidate: candidate)
            }
        }
    }
}

struct LargeLayout: View {
    let content: WidgetContent
    let candidate: Candidate

    struct Candidate: Equatable {
        var shown: Int
        /// Rows drawn per account before "+N more" (`Int.max`: all).
        var rowLimit = Int.max
        /// The medium widget's spacing, for when the roomier one does not fit.
        var dense = false
        /// Stale marks in the account headers, not on lines of their own.
        var staleInHeader = false
        /// The other providers' accounts (Codex) on one line each: the last
        /// resort, so Codex is shortened but never left out.
        var compactOthers = false
    }

    init(content: WidgetContent, candidate: Candidate) {
        // Accounts older than this layout's footer say so on their own line.
        self.content = content.markingOwnTimes(footer: Self.asOf(in: content, shown: candidate.shown))
        self.candidate = candidate
    }

    var shown: Int { candidate.shown }

    /// The layouts to try, roomiest first, every account shown until rows
    /// are down to two: everything in full; tighter spacing; stale lines in
    /// the headers; rows cut to three, then two. Then accounts are left out
    /// down to the active one plus Codex, and last Codex goes on one line.
    static func candidates(in content: WidgetContent) -> [Candidate] {
        let count = content.sections.flatMap(\.accounts).count
        let fewest = min(count, max(min(1, count), content.pinnedCount))
        let stale = content.sections.flatMap(\.accounts).contains(where: \.hasStaleLine)
        var list = [Candidate(shown: count),
                    Candidate(shown: count, dense: true)]
        if stale { list.append(Candidate(shown: count, dense: true, staleInHeader: true)) }
        list.append(Candidate(shown: count, rowLimit: 3, dense: true, staleInHeader: stale))
        list += (fewest...count).reversed().map { Candidate(shown: $0, rowLimit: 2, dense: true, staleInHeader: stale) }
        if !content.otherProviderAccounts.isEmpty {
            list.append(Candidate(shown: fewest, rowLimit: 2, dense: true, staleInHeader: stale, compactOthers: true))
        }
        return list
    }

    static func asOf(in content: WidgetContent, shown: Int) -> Date? {
        content.footerTime(for: visible(in: content, shown: shown))
    }

    /// The first `shown` accounts by priority, never fewer than the pinned
    /// ones, drawn in provider and slot order.
    static func visible(in content: WidgetContent, shown: Int) -> [WidgetContent.Account] {
        let kept = content.accountsByPriority.prefix(max(shown, content.pinnedCount))
        return content.sections.flatMap(\.accounts).filter(kept.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            grid
            Spacer(minLength: 4)  // the as of line sits at the bottom
            AsOfLine(date: Self.asOf(in: content, shown: shown), now: content.date, footer: content.refreshFooter,
                     notUpdating: content.notUpdating)
        }
    }

    private var grid: some View {
        let visible = Self.visible(in: content, shown: shown)
        let hidden = content.sections.flatMap(\.accounts).count - visible.count
        // Left out accounts all belong to the featured account's provider,
        // so the "more" line closes that provider's list.
        let home = content.homeSection?.provider
        let limit = candidate.rowLimit
        let dense = candidate.dense
        let reservesMarker = visible.contains { $0.compactRows(limit: limit).rows.contains(where: \.overMarker) }
        let gap = dense ? Style.denseAccountGap : Style.largeAccountGap

        // Each account's header names it ("Codex Pro"), so providers need no titles.
        return Grid(alignment: .leading, horizontalSpacing: Style.columnSpacing,
                    verticalSpacing: dense ? Style.rowSpacing : Style.largeRowSpacing) {
            ForEach(Array(content.sections.enumerated()), id: \.offset) { sectionIndex, section in
                let accounts = visible.filter { section.accounts.contains($0) }
                if sectionIndex > 0 {
                    Color.clear.frame(height: gap)
                        .gridCellUnsizedAxes(.horizontal)
                }
                if section.accounts.isEmpty {
                    NoAccountsRow()
                }
                ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                    if index > 0 {
                        Color.clear.frame(height: gap)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                    if candidate.compactOthers, section.provider != home {
                        CompactAccountRow(account: account, now: content.date)
                    } else {
                        AccountBlock(account: account, now: content.date, rowLimit: limit, reservesMarker: reservesMarker,
                                     staleInHeader: candidate.staleInHeader, countsHiddenRows: limit > 2)
                    }
                }
                if section.provider == home, hidden > 0 {
                    MoreRow(count: hidden)
                }
            }
        }
    }
}

/// One account: its header, its note, then its rows (cut to `rowLimit`,
/// with a "+N more" line for the rest). With `staleInHeader` the stale
/// mark sits in the header ("stale 5:30 AM") instead of on its own line.
private struct AccountBlock: View {
    let account: WidgetContent.Account
    let now: Date
    let rowLimit: Int
    let reservesMarker: Bool
    var staleInHeader = false
    /// "+N more" under rows cut to fit. The two row cut leaves it out: it
    /// is there to fit every account, and the line would cost the height
    /// the cut saves.
    var countsHiddenRows = true

    var body: some View {
        let compact = account.compactRows(limit: rowLimit)
        AccountHeader(account: account, staleSince: staleInHeader && account.hasStaleLine ? account.staleSince : nil,
                      now: now, omitted: account.omittedRows(limit: rowLimit))
        NoteRow(account: account, now: now, staleInHeader: staleInHeader)
        ForEach(Array(compact.rows.enumerated()), id: \.offset) { _, row in
            WindowRowView(row: row, reservesMarker: reservesMarker)
        }
        if compact.hidden > 0, countsHiddenRows {
            MoreWindowsRow(count: compact.hidden)
        }
    }
}

/// The footer: "as of 12:04 PM" (when the oldest current, not stale numbers
/// on screen were measured, never newer than any of them), "Refreshing…" while a press of the refresh
/// button is being answered, or "Not updating" when the agent has stopped
/// writing, with the refresh control at the right.
struct AsOfLine: View {
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.calendar) private var calendar
    @Environment(\.refreshControl) private var refreshControl
    let date: Date?
    let now: Date
    var footer: RefreshFooter = .none
    var notUpdating = false

    var body: some View {
        let text = Self.text(date: date, footer: footer, now: now, locale: locale, timeZone: timeZone,
                             calendar: calendar, notUpdating: notUpdating)
        if text != nil || refreshControl != nil {
            // The control sits over the line's right end, so the footer is
            // exactly one line of text high and every layout fits as before.
            Text(verbatim: text ?? " ")
                .font(Style.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.trailing, refreshControl == nil ? 0 : 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if let refreshControl {
                        refreshControl
                    }
                }
        }
    }

    static func text(date: Date?, footer: RefreshFooter, now: Date, locale: Locale, timeZone: TimeZone,
                     calendar: Calendar, notUpdating: Bool = false) -> String? {
        switch footer {
        case .refreshing:
            return "Refreshing\u{2026}"
        case .none:
            // The agent's snapshot stopped arriving: say so, since the
            // numbers will not move until it runs again.
            if notUpdating { return "Not updating; open Usage Widget" }
            return date.map { TimeText.asOf($0, relativeTo: now, locale: locale, timeZone: timeZone, calendar: calendar) }
        }
    }
}

private struct MoreRow: View {
    let count: Int

    var body: some View {
        IndentedLine {
            Text(count == 1 ? "1 more account" : "\(count) more accounts")
                .font(Style.label)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NoAccountsRow: View {
    var body: some View {
        Text("No accounts yet")
            .font(Style.label)
            .foregroundStyle(.secondary)
            .gridCellUnsizedAxes(.horizontal)
    }
}
