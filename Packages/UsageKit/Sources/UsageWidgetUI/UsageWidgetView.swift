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
        WidgetFrame(content: content, size: size) {
            switch size {
            case .medium:
                if let last = MediumLayout.candidates(in: content).last {
                    MediumLayout(content: content, candidate: last)
                }
            case .large:
                if let last = LargeLayout.candidates(in: content).last {
                    LargeLayout(content: content, candidate: last)
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
            .contentShape(Rectangle())
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

    struct Candidate: Equatable {
        var visibleOthers: Int
        var featuredRows: Int
    }

    init(content: WidgetContent, visibleOthers: Int, featuredRows: Int = 3) {
        self.content = content
        self.visibleOthers = visibleOthers
        self.featuredRows = featuredRows
    }

    init(content: WidgetContent, candidate: Candidate) {
        self.init(content: content, visibleOthers: candidate.visibleOthers, featuredRows: candidate.featuredRows)
    }

    /// The layouts to try: every other account, then fewer, never below the
    /// other providers' lines (Codex); then, only if that still does not
    /// fit, the featured account cut to two rows and then one.
    static func candidates(in content: WidgetContent) -> [Candidate] {
        let fewest = fewestOthers(in: content)
        var list = (fewest...others(in: content).count).reversed().map { Candidate(visibleOthers: $0, featuredRows: 3) }
        if fewest > 0 {
            list += [Candidate(visibleOthers: fewest, featuredRows: 2), Candidate(visibleOthers: fewest, featuredRows: 1)]
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
        WidgetContent.asOf(of: shown(in: content, visibleOthers: visibleOthers))
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
                             reservesMarker: featured.compactRows(limit: featuredRows).rows.contains(where: \.overMarker))
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
/// widget's, then each account is cut to three rows, and then Claude
/// accounts are left out from the end of the list, never the active one
/// and never Codex.
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
    let shown: Int
    let collapsed: Bool
    /// The medium widget's spacing, for when the roomier one does not fit.
    var dense = false
    /// The other providers' accounts (Codex) on one line each: the last
    /// resort, so Codex is shortened but never left out.
    var compactOthers = false

    struct Candidate: Equatable {
        var shown: Int
        var collapsed: Bool
        var dense: Bool
        var compactOthers: Bool
    }

    init(content: WidgetContent, shown: Int, collapsed: Bool, dense: Bool = false, compactOthers: Bool = false) {
        self.content = content
        self.shown = shown
        self.collapsed = collapsed
        self.dense = dense
        self.compactOthers = compactOthers
    }

    init(content: WidgetContent, candidate: Candidate) {
        self.init(content: content, shown: candidate.shown, collapsed: candidate.collapsed, dense: candidate.dense,
                  compactOthers: candidate.compactOthers)
    }

    /// The layouts to try, roomiest first: everything in full, the same
    /// with tighter spacing, rows cut to three while accounts are left out
    /// down to the active one plus Codex, and last Codex on one line.
    static func candidates(in content: WidgetContent) -> [Candidate] {
        let count = content.sections.flatMap(\.accounts).count
        let fewest = min(count, max(min(1, count), content.pinnedCount))
        var list = [Candidate(shown: count, collapsed: false, dense: false, compactOthers: false),
                    Candidate(shown: count, collapsed: false, dense: true, compactOthers: false)]
        list += (fewest...count).reversed().map { Candidate(shown: $0, collapsed: true, dense: false, compactOthers: false) }
        if !content.otherProviderAccounts.isEmpty {
            list.append(Candidate(shown: fewest, collapsed: true, dense: true, compactOthers: true))
        }
        return list
    }

    static func asOf(in content: WidgetContent, shown: Int) -> Date? {
        WidgetContent.asOf(of: visible(in: content, shown: shown))
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
        let limit = collapsed ? 3 : Int.max
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
                    if compactOthers, section.provider != home {
                        CompactAccountRow(account: account, now: content.date)
                    } else {
                        AccountBlock(account: account, now: content.date, rowLimit: limit, reservesMarker: reservesMarker)
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
/// with a "+N more" line for the rest).
private struct AccountBlock: View {
    let account: WidgetContent.Account
    let now: Date
    let rowLimit: Int
    let reservesMarker: Bool

    var body: some View {
        let compact = account.compactRows(limit: rowLimit)
        AccountHeader(account: account)
        NoteRow(account: account, now: now)
        ForEach(Array(compact.rows.enumerated()), id: \.offset) { _, row in
            WindowRowView(row: row, reservesMarker: reservesMarker)
        }
        if compact.hidden > 0 {
            MoreWindowsRow(count: compact.hidden)
        }
    }
}

/// The footer: "as of 12:04 PM" (when the oldest current numbers on
/// screen were measured), "Refreshing…" while a press of the refresh
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
