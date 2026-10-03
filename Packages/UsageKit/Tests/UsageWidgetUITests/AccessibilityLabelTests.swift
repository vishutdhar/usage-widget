import XCTest
import UsageCore
@testable import UsageWidgetUI

final class AccessibilityLabelTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    let english = Locale(identifier: "en_US")

    func row(_ window: UsageWindow) -> WindowRow {
        UsageDisplay.row(for: window, at: now)
    }

    func testUnknownIsSpokenAsUnknown() {
        let unknown = row(UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: nil))
        XCTAssertEqual(Accessibility.label(for: unknown, locale: english), "7 day unknown")
    }

    func testSpendIncludesTheAmounts() {
        let spend = row(UsageWindow(kind: .spend, name: "Spend", windowSeconds: 0, usedPct: 80,
                                    amount: 80, limit: 100, currency: "USD"))
        XCTAssertEqual(Accessibility.label(for: spend, locale: english), "Spend 80 percent, $80 of $100")
    }

    func testOrdinaryRows() {
        let over = row(UsageWindow(kind: .model, name: "Fable", windowSeconds: 604_800, usedPct: 100))
        XCTAssertEqual(Accessibility.label(for: over, locale: english), "Fable 100 percent, over limit")
    }

    /// The one-line VoiceOver label carries the note and when the numbers
    /// were last known, as the screen does.
    func testTheCompactLabelIncludesTheLastKnownTime() {
        let entry = ISODate.parse("2026-09-27T12:04:00Z")!
        let lastKnown = entry.addingTimeInterval(-50 * 3600)
        let account = WidgetContent.Account(id: "2", label: "sam@example.com", active: false, rows: [],
                                            note: "Log in again", lastKnownAt: lastKnown)
        let utc = TimeZone(identifier: "UTC")!
        let calendar = Calendar(identifier: .gregorian)
        let label = Accessibility.label(for: account, locale: english, timeZone: utc, calendar: calendar, now: entry)
        let expected = TimeText.noteLine("Log in again", lastKnownAt: lastKnown, relativeTo: entry, locale: english,
                                         timeZone: utc, calendar: calendar)
        XCTAssertTrue(label.contains(expected), label)
        XCTAssertTrue(label.contains("last known as of Sep 25"), label)
    }

    /// Current numbers past their line are spoken as stale with their time,
    /// as the screen shows them.
    func testTheLabelSaysOldNumbersAreStale() {
        let entry = ISODate.parse("2026-09-27T12:04:00Z")!
        let measured = entry.addingTimeInterval(-16 * 3600)
        var account = WidgetContent.Account(id: "1", label: "alex@example.com", active: true, rows: [], note: nil)
        account.staleSince = measured
        let utc = TimeZone(identifier: "UTC")!
        let calendar = Calendar(identifier: .gregorian)
        let label = Accessibility.label(for: account, locale: english, timeZone: utc, calendar: calendar, now: entry)
        XCTAssertTrue(label.contains("stale \u{00B7} as of 8:04\u{202F}PM yesterday"), label)
    }

    @MainActor
    func testTheAsOfLineUsesOnlyTheAccountsALayoutShows() {
        let entry = ISODate.parse("2026-09-27T12:04:00Z")!
        func account(_ id: String, active: Bool, measured: Date) -> AccountUsage {
            AccountUsage(id: id, label: "\(id)@example.com", active: active, fetchedAt: measured, windows: [
                UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 10),
            ])
        }
        let snapshot = UsageSnapshot(writtenAt: entry, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                account("1", active: true, measured: entry.addingTimeInterval(-60)),
                account("2", active: false, measured: entry.addingTimeInterval(-30 * 60)),
            ]),
        ])
        let content = WidgetContent.make(snapshot: snapshot, at: entry)
        XCTAssertEqual(MediumLayout.shown(in: content, visibleOthers: 0).map(\.id), ["1"])
        XCTAssertEqual(MediumLayout.asOf(in: content, visibleOthers: 0), entry.addingTimeInterval(-60))
        XCTAssertEqual(MediumLayout.asOf(in: content, visibleOthers: 1), entry.addingTimeInterval(-30 * 60),
                       "the oldest of the accounts shown")
        XCTAssertEqual(LargeLayout.asOf(in: content, shown: 1), entry.addingTimeInterval(-60))
    }

    /// Rows a layout leaves out are still spoken, with the header: the two
    /// row cut drops the 5 hour window, and VoiceOver still hears it.
    func testOmittedWindowsAreStillSpoken() {
        let now = ISODate.parse("2026-09-27T12:04:00Z")!
        let rows = [UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 100),
                    UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 50),
                    UsageWindow(kind: .model, name: "Fable", windowSeconds: 604_800, usedPct: 90)]
            .map { UsageDisplay.row(for: $0, at: now) }
        let account = WidgetContent.Account(id: "1", label: "a@example.com", active: true, rows: rows, note: nil)
        XCTAssertEqual(account.omittedRows(limit: 2).map(\.label), ["5h"])
        XCTAssertEqual(account.omittedRows(limit: 3), [])
        let header = Accessibility.header(for: account, omitted: account.omittedRows(limit: 2), locale: english)
        XCTAssertEqual(header, "Account 1, a@example.com, active, 5 hour 100 percent, over limit, not shown")
    }
}
