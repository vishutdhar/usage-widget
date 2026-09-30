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
        let lastKnown = entry.addingTimeInterval(-26 * 3600)
        let account = WidgetContent.Account(id: "2", label: "sam@example.com", active: false, rows: [],
                                            note: "Log in again", lastKnownAt: lastKnown)
        let utc = TimeZone(identifier: "UTC")!
        let calendar = Calendar(identifier: .gregorian)
        let label = Accessibility.label(for: account, locale: english, timeZone: utc, calendar: calendar, now: entry)
        let expected = TimeText.noteLine("Log in again", lastKnownAt: lastKnown, relativeTo: entry, locale: english,
                                         timeZone: utc, calendar: calendar)
        XCTAssertTrue(label.contains(expected), label)
        XCTAssertTrue(label.contains("last known as of Sep 26"), label)
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
                account("2", active: false, measured: entry.addingTimeInterval(-86_400)),
            ]),
        ])
        let content = WidgetContent.make(snapshot: snapshot, at: entry)
        XCTAssertEqual(MediumLayout.shown(in: content, visibleOthers: 0).map(\.id), ["1"])
        XCTAssertEqual(MediumLayout.asOf(in: content, visibleOthers: 0), entry.addingTimeInterval(-60))
        XCTAssertEqual(MediumLayout.asOf(in: content, visibleOthers: 1), entry.addingTimeInterval(-86_400))
        XCTAssertEqual(LargeLayout.asOf(in: content, shown: 1), entry.addingTimeInterval(-60))
    }
}
