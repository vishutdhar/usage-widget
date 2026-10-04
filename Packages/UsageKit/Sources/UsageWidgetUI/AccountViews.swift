import SwiftUI
import UsageCore

/// The header line of one account: accent dot when active, slot number,
/// label, the plan when the provider reports one, and on the right the
/// footnote ("2 resets available"), the stale mark when the layout put it
/// here ("stale 5:30 AM"), and "active".
struct AccountHeader: View {
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.calendar) private var calendar
    let account: WidgetContent.Account
    var staleSince: Date?
    var now = Date()
    /// Rows the layout left out, spoken with the header.
    var omitted: [WindowRow] = []

    var body: some View {
        HStack(spacing: Style.columnSpacing) {
            Circle()
                .fill(account.active ? Color.accentColor : Color.clear)
                .frame(width: Style.dot, height: Style.dot)
            if showsNumber {
                Text(account.id)
                    .font(Style.title)
                    .foregroundStyle(.secondary)
            }
            Text(account.label)
                .font(account.active ? Style.titleActive : Style.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = account.detail {
                Text(verbatim: detail)
                    .font(Style.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            ForEach(Self.rightSide(of: account, tag: tag), id: \.self) { text in
                Text(verbatim: text)
                    .font(Style.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()  // the label gives way, these never truncate
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Accessibility.header(for: account, staleTag: tag, omitted: omitted, locale: locale))
        .gridCellUnsizedAxes(.horizontal)
    }

    /// cswap slots are numbered; other providers may use longer ids.
    private var showsNumber: Bool { account.id.count <= 3 }

    /// What the header's right side says: the footnote, then the stale mark
    /// when the layout put it here, else "active".
    static func rightSide(of account: WidgetContent.Account, tag: String?) -> [String] {
        [account.footnote, tag ?? (account.active ? "active" : nil)].compactMap { $0 }
    }

    private var tag: String? {
        staleSince.map { TimeText.staleTag(since: $0, relativeTo: now, locale: locale, timeZone: timeZone, calendar: calendar) }
    }
}

/// One window as a grid row: label, bar, over marker, percent, and the reset
/// countdown (or, for spend, the amount against the limit).
struct WindowRowView: View {
    @Environment(\.locale) private var locale
    let row: WindowRow
    let reservesMarker: Bool

    var body: some View {
        GridRow {
            Color.clear.frame(width: Style.dot, height: 1)
            Text(row.label)
                .font(Style.label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .gridColumnAlignment(.leading)
            UsageBar(fraction: row.fraction, level: row.level, paceFraction: row.paceFraction)
                .frame(minWidth: 40)
            if reservesMarker {
                Text(row.overMarker ? "(!)" : "")
                    .font(Style.digits)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
            Text(row.percentText)
                .font(Style.digits)
                .gridColumnAlignment(.trailing)
            Group {
                if let spend = row.spend {
                    Text(verbatim: UsageDisplay.spendText(amount: spend.amount, limit: spend.limit,
                                                          currency: spend.currency, locale: locale) ?? "")
                        .font(Style.digits)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    ResetText(date: row.resetsAt)
                }
            }
            .padding(.leading, Style.resetLeadingGap)
            .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Accessibility.label(for: row, locale: locale))
    }
}

/// Time until the window resets. Text with a date style keeps counting
/// between widget reloads.
struct ResetText: View {
    let date: Date?

    var body: some View {
        if let date {
            Text(date, style: .relative)
                .font(Style.digits)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("")
        }
    }
}

/// A full-width line indented to the row labels, outside the grid's columns.
struct IndentedLine<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Style.columnSpacing) {
            Color.clear.frame(width: Style.dot, height: 1)
            content
        }
        .gridCellUnsizedAxes(.horizontal)
    }
}

/// The account's status note, with when its last known numbers were
/// measured: "Log in again, last known as of 10:04 AM".
struct NoteRow: View {
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.calendar) private var calendar
    let account: WidgetContent.Account
    let now: Date
    /// The stale mark is in the header: it gets no line of its own.
    var staleInHeader = false

    var body: some View {
        if let line = NoteRow.shownLine(for: account, staleInHeader: staleInHeader, now: now, locale: locale,
                                        timeZone: timeZone, calendar: calendar) {
            IndentedLine {
                Text(verbatim: line)
                    .font(Style.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

extension NoteRow {
    /// The line this row draws: with the stale mark in the header, only the
    /// stale line is left out; a note or an "as of" own time still shows.
    static func shownLine(for account: WidgetContent.Account, staleInHeader: Bool, now: Date, locale: Locale,
                          timeZone: TimeZone, calendar: Calendar) -> String? {
        staleInHeader && account.hasStaleLine ? nil
            : line(for: account, now: now, locale: locale, timeZone: timeZone, calendar: calendar)
    }

    /// The account's note with its last known time, or for current numbers
    /// past their line "stale · as of 7:08 PM yesterday"; nil otherwise.
    nonisolated static func line(for account: WidgetContent.Account, now: Date, locale: Locale, timeZone: TimeZone,
                     calendar: Calendar) -> String? {
        if let note = account.note {
            return TimeText.noteLine(note, lastKnownAt: account.lastKnownAt, relativeTo: now, locale: locale,
                                     timeZone: timeZone, calendar: calendar)
        }
        if let since = account.staleSince {
            return TimeText.staleLine(since: since, relativeTo: now, locale: locale, timeZone: timeZone, calendar: calendar)
        }
        // Older than the footer says: "as of" its own time.
        return account.ownTime.map {
            TimeText.asOf($0, relativeTo: now, locale: locale, timeZone: timeZone, calendar: calendar)
        }
    }
}

/// "+3 more" under an account whose rows were cut to fit.
struct MoreWindowsRow: View {
    let count: Int

    var body: some View {
        IndentedLine {
            Text(verbatim: "+\(count) more")
                .font(Style.label)
                .foregroundStyle(.secondary)
        }
    }
}

/// Another account on one line, for the medium widget: at most three
/// windows as small band-coloured dots with their percents, then its note
/// if it has one; only an account with no numbers shows the note alone.
struct CompactAccountRow: View {
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.calendar) private var calendar
    let account: WidgetContent.Account
    let now: Date

    var body: some View {
        let compact = account.compactRows(limit: 3)
        IndentedLine {
            if account.id.count <= 3 {
                Text(account.id).font(Style.label).foregroundStyle(.secondary)
            }
            Text(CompactAccountRow.shortLabel(account.label))
                .font(Style.label)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            Spacer(minLength: 4)
            if compact.rows.isEmpty, let note = account.note {
                Text(verbatim: TimeText.noteLine(note, lastKnownAt: account.lastKnownAt, relativeTo: now,
                                                 locale: locale, timeZone: timeZone, calendar: calendar))
                    .font(Style.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-2)
            } else {
                // With numbers to show, they stay; when they are not current,
                // "as of" their time follows them and gives way first.
                ForEach(Array(compact.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(row.level.fillColor)
                            .frame(width: 5, height: 5)
                        Text(row.label).font(Style.label).foregroundStyle(.secondary)
                        Text(row.percentText).font(Style.digits)
                    }
                    .fixedSize()
                }
                if compact.hidden > 0 {
                    Text(verbatim: "+\(compact.hidden)").font(Style.label).foregroundStyle(.secondary).fixedSize()
                }
                if let note = CompactAccountRow.trailingNote(for: account, now: now, locale: locale, timeZone: timeZone,
                                                             calendar: calendar) {
                    Text(verbatim: note)
                        .font(Style.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Accessibility.label(for: account, locale: locale, timeZone: timeZone, calendar: calendar,
                                                now: now))
    }

    /// What follows the numbers on one line: nothing while they are
    /// current; otherwise when they were last known ("as of 10:04 AM", or
    /// with the day when it is another), which also says they are not
    /// current. Without a known time, the account's note.
    static func trailingNote(for account: WidgetContent.Account, now: Date, locale: Locale, timeZone: TimeZone,
                             calendar: Calendar) -> String? {
        guard let note = account.note else {
            // One line has room for the short mark only: "stale 5:30 AM".
            if let since = account.staleSince {
                return TimeText.staleTag(since: since, relativeTo: now, locale: locale, timeZone: timeZone,
                                         calendar: calendar)
            }
            // Older than the footer says: "as of" its own time.
            return account.ownTime.map {
                TimeText.asOf($0, relativeTo: now, locale: locale, timeZone: timeZone, calendar: calendar)
            }
        }
        guard let known = account.lastKnownAt else { return note }
        return TimeText.asOf(known, relativeTo: now, locale: locale, timeZone: timeZone, calendar: calendar)
    }

    /// The part of an email before the "@": on one line with three windows
    /// there is room for a name, not an address.
    static func shortLabel(_ label: String) -> String {
        guard let at = label.firstIndex(of: "@"), at > label.startIndex else { return label }
        return String(label[..<at])
    }
}

enum Accessibility {
    /// "Account 1, alex@example.com" for a numbered slot, "Codex, Pro plan"
    /// for a provider's single account.
    static func name(of account: WidgetContent.Account) -> String {
        var name = account.id.count <= 3 ? "Account \(account.id), \(account.label)" : account.label
        if let detail = account.detail { name += ", \(detail) plan" }
        return name
    }

    /// The header as spoken; rows the layout left out are spoken here too
    /// ("5 hour 100 percent, over limit, not shown"), so VoiceOver hears
    /// every window whatever the layout drew.
    static func header(for account: WidgetContent.Account, staleTag: String? = nil, omitted: [WindowRow] = [],
                       locale: Locale = .current) -> String {
        ([name(of: account)] + [account.footnote, staleTag, account.active ? "active" : nil].compactMap { $0 }
            + omitted.map { label(for: $0, locale: locale) + ", not shown" })
            .joined(separator: ", ")
    }

    static func label(for row: WindowRow, locale: Locale) -> String {
        if row.level == .unknown { return "\(spokenName(row.label)) unknown" }
        var parts = ["\(spokenName(row.label)) \(row.percentText.dropLast()) percent"]
        if row.overMarker {
            parts.append("over limit")
        } else if row.aheadOfPace {
            parts.append("ahead of pace")
        }
        if let spend = row.spend,
           let text = UsageDisplay.spendText(amount: spend.amount, limit: spend.limit, currency: spend.currency,
                                             locale: locale) {
            parts.append(text)
        }
        return parts.joined(separator: ", ")
    }

    static func label(for account: WidgetContent.Account, locale: Locale, timeZone: TimeZone, calendar: Calendar,
                      now: Date) -> String {
        var parts = [name(of: account)]
        if account.active { parts.append("active") }
        if let line = NoteRow.line(for: account, now: now, locale: locale, timeZone: timeZone, calendar: calendar) {
            parts.append(line)
        }
        parts += account.rows.map { label(for: $0, locale: locale) }
        if let footnote = account.footnote { parts.append(footnote) }
        return parts.joined(separator: ". ")
    }

    private static func spokenName(_ label: String) -> String {
        switch label {
        case "5h": return "5 hour"
        case "7d": return "7 day"
        default: return label
        }
    }
}
