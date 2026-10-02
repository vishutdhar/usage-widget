import XCTest
@testable import UsageCore

final class WidgetContentTests: XCTestCase {
    let now = utc(2026, 1, 15, 10, 5, 0)

    func sampleSnapshot(status: ProviderUsage.Status = .ok, error: String? = nil) throws -> UsageSnapshot {
        let accounts = try CswapListMapper.accounts(from: fixture("cswap-list-sample"))
        guard accounts.count == 3 else { throw IndexMissing(index: 2, count: accounts.count) }
        return UsageSnapshot(writtenAt: now, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: status, error: error, accounts: accounts),
        ])
    }

    func testNoSnapshotIsTheEmptyState() {
        let content = WidgetContent.make(snapshot: nil, at: now)
        XCTAssertFalse(content.hasSnapshot)
        XCTAssertEqual(content.sections, [])
    }

    func testSampleSnapshotBuildsOneSectionWithEveryAccount() throws {
        let content = WidgetContent.make(snapshot: try sampleSnapshot(), at: now)
        XCTAssertTrue(content.hasSnapshot)
        XCTAssertEqual(content.sections.map(\.provider), ["claude"])
        XCTAssertEqual(try content.sections[at: 0].title, "Claude")
        XCTAssertNil(try content.sections[at: 0].errorText)
        let accounts = try content.sections[at: 0].accounts
        XCTAssertEqual(accounts.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(try accounts[at: 0].rows.map(\.label), ["5h", "7d", "Fable"])
        XCTAssertEqual(try accounts[at: 0].rows.map(\.percentText), ["20%", "80%", "100%"])
        XCTAssertEqual(try accounts[at: 0].rows.map(\.level), [.ok, .warn, .over])
        XCTAssertNil(try accounts[at: 0].note)
        XCTAssertEqual(WidgetContent.asOf(of: accounts), utc(2026, 1, 15, 9, 58, 0), "the oldest of the three shown")
    }

    func testErrorReasonTravelsWithTheLastKnownData() throws {
        let content = WidgetContent.make(snapshot: try sampleSnapshot(status: .error, error: "cswap not found"), at: now)
        XCTAssertEqual(try content.sections[at: 0].errorText, "cswap not found")
        XCTAssertEqual(try content.sections[at: 0].accounts.count, 3)
    }

    func testAProviderErrorShowsEvenWhenCswapIsFine() throws {
        var snapshot = try sampleSnapshot()
        snapshot.providers[0].error = "Reload state could not be saved: Is a directory"
        let content = WidgetContent.make(snapshot: snapshot, at: now)
        XCTAssertEqual(try content.sections[at: 0].errorText, "Reload state could not be saved: Is a directory")
    }

    func testAccountWithoutWindowsGetsTheUnavailableNote() throws {
        var snapshot = try sampleSnapshot()
        snapshot.providers[0].accounts[1].windows = []
        let account = try WidgetContent.make(snapshot: snapshot, at: now).sections[at: 0].accounts[at: 1]
        XCTAssertEqual(account.rows, [])
        XCTAssertEqual(account.note, "Usage unavailable")
    }

    func testDimmingFollowsEachAccountsOwnMeasurementAtTheEntryDate() throws {
        let snapshot = try sampleSnapshot()
        let early = WidgetContent.make(snapshot: snapshot, at: utc(2026, 1, 15, 11, 59, 0))
        XCTAssertEqual(try early.sections[at: 0].accounts.map(\.dimmed), [false, false, true],
                       "account 3 was measured at 09:58, more than two hours before 11:59")
        let late = WidgetContent.make(snapshot: snapshot, at: utc(2026, 1, 15, 12, 1, 0))
        XCTAssertEqual(try late.sections[at: 0].accounts.map(\.dimmed), [true, true, true])
        XCTAssertEqual(late.date, utc(2026, 1, 15, 12, 1, 0))
    }

    func testNonOkAccountsShowTheirNoteAndWhenTheirNumbersWereLastKnown() throws {
        let accounts = try CswapListMapper.accounts(from: fixture("cswap-list-statuses"))
        let snapshot = UsageSnapshot(writtenAt: utc(2026, 9, 27, 10, 0, 0), providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: accounts),
        ])
        let date = utc(2026, 9, 27, 10, 5, 0)
        let shown = try WidgetContent.make(snapshot: snapshot, at: date).sections[at: 0].accounts
        let posix = Locale(identifier: "en_US_POSIX")
        let lines = shown.map { account -> String in
            let line = account.note.map {
                TimeText.noteLine($0, lastKnownAt: account.lastKnownAt, relativeTo: date, locale: posix,
                                  timeZone: TimeZone(identifier: "UTC")!, calendar: Calendar(identifier: .gregorian))
            }
            return "\(account.id) \(account.dimmed ? "dim" : "lit") \(line ?? "-")"
        }
        XCTAssertEqual(lines, [
            "1 lit -",
            "2 dim Log in again, last known as of 10:00\u{202F}AM yesterday",
            "3 lit No saved login",
            "4 dim Token expired, last known as of 8:00\u{202F}AM",
            "5 lit Keychain locked",
            "6 lit Signed in as another account",
            "7 lit API key, no plan limits",
            "8 lit Usage unavailable (http-429)",
            "9 lit Usage unavailable",
            "10 lit Usage unavailable",
        ])
    }

    func testAsOfCountsOnlyCurrentAccounts() throws {
        let accounts = try CswapListMapper.accounts(from: fixture("cswap-list-statuses"))
        let snapshot = UsageSnapshot(writtenAt: utc(2026, 9, 27, 10, 0, 0), providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: accounts),
        ])
        let shown = try WidgetContent.make(snapshot: snapshot, at: utc(2026, 9, 27, 10, 5, 0)).sections[at: 0].accounts
        XCTAssertEqual(WidgetContent.asOf(of: shown), utc(2026, 9, 27, 10, 0, 0),
                       "day-old last known numbers carry their own time")
    }

    /// The footer speaks only for the accounts on screen: one the layout
    /// left out, measured yesterday, does not drag it back.
    func testAsOfCountsOnlyTheAccountsShown() throws {
        var snapshot = try sampleSnapshot()
        snapshot.providers[0].accounts[2].fetchedAt = utc(2026, 1, 14, 9, 0, 0)
        let accounts = try WidgetContent.make(snapshot: snapshot, at: now).sections[at: 0].accounts
        XCTAssertEqual(WidgetContent.asOf(of: Array(accounts.prefix(2))), utc(2026, 1, 15, 10, 0, 0))
        XCTAssertEqual(WidgetContent.asOf(of: accounts), utc(2026, 1, 14, 9, 0, 0))
    }

    func testCompactRowsKeepFiveHourSevenDayAndTheBusiestModel() {
        let now = utc(2026, 9, 27)
        var windows = [
            UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 10),
            UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 50),
        ]
        for (index, pct) in [20.0, 70, 95, 40, 10, 5, 60, 30].enumerated() {
            windows.append(UsageWindow(kind: .model, name: "M\(index)", windowSeconds: 604_800, usedPct: pct))
        }
        windows.append(UsageWindow(kind: .spend, name: "Spend", windowSeconds: 0, usedPct: 99,
                                   amount: 99, limit: 100, currency: "USD"))
        let account = WidgetContent.account(from: AccountUsage(id: "1", label: "a", active: true, fetchedAt: now,
                                                               windows: windows), at: now, provider: "claude")
        let compact = account.compactRows(limit: 3)
        XCTAssertEqual(compact.rows.map(\.label), ["5h", "7d", "M2"])
        XCTAssertEqual(compact.hidden, 8)
        XCTAssertEqual(account.compactRows(limit: .max).rows.count, 11)
        XCTAssertEqual(account.compactRows(limit: .max).hidden, 0)
    }

    func testCompactRowsTopUpWhenThereIsNoSessionOrWeekly() {
        let now = utc(2026, 9, 27)
        let windows = [
            UsageWindow(kind: .model, name: "A", windowSeconds: 604_800, usedPct: 10),
            UsageWindow(kind: .model, name: "B", windowSeconds: 604_800, usedPct: nil),
            UsageWindow(kind: .spend, name: "Spend", windowSeconds: 0, usedPct: 5, amount: 5, limit: 100, currency: "USD"),
            UsageWindow(kind: .model, name: "C", windowSeconds: 604_800, usedPct: 30),
        ]
        let account = WidgetContent.account(from: AccountUsage(id: "1", label: "a", active: true, fetchedAt: now,
                                                               windows: windows), at: now, provider: "claude")
        let compact = account.compactRows(limit: 3)
        XCTAssertEqual(compact.rows.map(\.label), ["A", "B", "C"], "the busiest model, topped up with the rest in order")
        XCTAssertEqual(compact.hidden, 1)
    }

    func testRowsAreComputedAtTheEntryDate() throws {
        let snapshot = try sampleSnapshot()
        let afterFiveHourReset = utc(2026, 9, 27, 14, 30, 30)
        let row = try WidgetContent.make(snapshot: snapshot, at: afterFiveHourReset).sections[at: 0].accounts[at: 0].rows[at: 0]
        XCTAssertEqual(row.percentText, "0%")
        XCTAssertNil(row.resetsAt)
    }

    func testActiveFirstOrdering() throws {
        var snapshot = try sampleSnapshot()
        snapshot.providers[0].accounts[0].active = false
        snapshot.providers[0].accounts[1].active = true
        let section = try WidgetContent.make(snapshot: snapshot, at: now).sections[at: 0]
        XCTAssertEqual(section.accountsActiveFirst.map(\.id), ["2", "1", "3"])
        XCTAssertEqual(section.accounts.map(\.id), ["1", "2", "3"])
    }

    func testProviderTitles() {
        XCTAssertEqual(WidgetContent.title(forProvider: "claude"), "Claude")
        XCTAssertEqual(WidgetContent.title(forProvider: "codex"), "Codex")
        XCTAssertEqual(WidgetContent.title(forProvider: "other"), "Other")
    }
}
