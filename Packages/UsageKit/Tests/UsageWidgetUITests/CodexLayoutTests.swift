import XCTest
import UsageCore
@testable import UsageWidgetUI

@MainActor
final class CodexLayoutTests: XCTestCase {
    let entry = ISODate.parse("2026-09-27T12:04:00Z")!
    let english = Locale(identifier: "en_US")
    let utc = TimeZone(identifier: "UTC")!
    let calendar = Calendar(identifier: .gregorian)

    func content(activeSlot: String = "1", codexMeasured: Date? = nil) -> WidgetContent {
        func claude(_ id: String) -> AccountUsage {
            AccountUsage(id: id, label: "\(id)@example.com", active: id == activeSlot, fetchedAt: entry, windows: [
                UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 10),
            ])
        }
        let snapshot = UsageSnapshot(writtenAt: entry, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok,
                          accounts: ["1", "2", "3"].map(claude)),
            ProviderUsage(provider: "codex", source: "rollout", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: codexMeasured ?? entry, windows: [
                    UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 35),
                ]),
            ], extras: ["resetCreditsAvailable": .number(2), "planType": .string("pro")]),
        ])
        return WidgetContent.make(snapshot: snapshot, at: entry)
    }

    func testMediumPutsTheCodexLineRightAfterTheFeaturedAccount() {
        let c = content()
        XCTAssertEqual(MediumLayout.featured(in: c)?.id, "1")
        XCTAssertEqual(MediumLayout.others(in: c).map(\.id), ["codex", "2", "3"])
        XCTAssertEqual(MediumLayout.shown(in: c, visibleOthers: 1).map(\.id), ["1", "codex"])
    }

    /// Accounts left out for space come from the end of the Claude list;
    /// the active account and the Codex block stay.
    func testLargeKeepsTheActiveAccountAndCodexWhenShort() {
        let c = content(activeSlot: "3")
        XCTAssertEqual(LargeLayout.visible(in: c, shown: 4).map(\.id), ["1", "2", "3", "codex"], "slot order when all fit")
        XCTAssertEqual(LargeLayout.visible(in: c, shown: 2).map(\.id), ["3", "codex"])
        XCTAssertEqual(LargeLayout.visible(in: c, shown: 3).map(\.id), ["1", "3", "codex"])
        XCTAssertEqual(LargeLayout.visible(in: c, shown: 1).map(\.id), ["3", "codex"], "never fewer than active plus Codex")
    }

    /// Every layout the large widget may fall back to keeps Codex; the last
    /// one draws it as a single line.
    func testNoLargeFallbackDropsCodex() {
        let c = content(activeSlot: "2")
        let candidates = LargeLayout.candidates(in: c)
        for candidate in candidates {
            XCTAssertTrue(LargeLayout.visible(in: c, shown: candidate.shown).contains { $0.id == "codex" }, "\(candidate)")
        }
        XCTAssertEqual(candidates.last, LargeLayout.Candidate(shown: 2, collapsed: true, dense: true, compactOthers: true))
        XCTAssertEqual(candidates.filter(\.compactOthers).count, 1, "only the last resort draws Codex on one line")
    }

    func testNoMediumFallbackDropsCodex() {
        let c = content()
        XCTAssertEqual(MediumLayout.fewestOthers(in: c), 1, "the Codex line")
        let candidates = MediumLayout.candidates(in: c)
        XCTAssertTrue(candidates.allSatisfy { $0.visibleOthers >= 1 }, "\(candidates)")
        XCTAssertEqual(candidates.map(\.featuredRows), [3, 3, 3, 2, 1], "rows are cut only after the other lines")
        let claudeOnly = WidgetContent(hasSnapshot: true, sections: [c.sections[0]], date: entry)
        XCTAssertEqual(MediumLayout.fewestOthers(in: claudeOnly), 0)
    }

    /// "as of" covers the Codex numbers whenever the layout shows them.
    func testAsOfCoversCodex() {
        let older = entry.addingTimeInterval(-40 * 60)
        let c = content(codexMeasured: older)
        XCTAssertEqual(MediumLayout.asOf(in: c, visibleOthers: 0), entry)
        XCTAssertEqual(MediumLayout.asOf(in: c, visibleOthers: 1), older)
        XCTAssertEqual(LargeLayout.asOf(in: c, shown: 4), older)
        XCTAssertEqual(LargeLayout.asOf(in: c, shown: 1), older, "Codex is on every large layout")
    }

    func withErrors(claude: String?, codex: String?, claudeAccounts: Bool = true) -> WidgetContent {
        var snapshot = UsageSnapshot(writtenAt: entry, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: claude == nil ? .ok : .error, error: claude,
                          accounts: claudeAccounts ? [AccountUsage(id: "1", label: "a@example.com", active: true,
                                                                   fetchedAt: entry, windows: [])] : []),
            ProviderUsage(provider: "codex", source: "rollout", status: codex == nil ? .ok : .error, error: codex,
                          accounts: [AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: entry,
                                                  windows: [])]),
        ])
        snapshot.writtenAt = entry
        return WidgetContent.make(snapshot: snapshot, at: entry)
    }

    /// The medium widget keeps its one Codex line: Codex's own error does
    /// not take a top line there, since that line shows Codex's state.
    func testMediumShowsOnlyTheFeaturedProvidersError() {
        let both = withErrors(claude: "cswap not found", codex: "codex app-server did not answer within 20 s")
        XCTAssertEqual(ErrorLines.lines(for: both, size: .medium), ["Claude: cswap not found"])
        XCTAssertEqual(ErrorLines.lines(for: both, size: .large),
                       ["Claude: cswap not found", "Codex app-server did not answer within 20 s"])
    }

    /// With no Claude accounts at all, Codex is featured and Claude's error
    /// is the only sign of why Claude is missing.
    func testAProviderWithoutAccountsKeepsItsError() {
        let c = withErrors(claude: "cswap not found", codex: nil, claudeAccounts: false)
        XCTAssertEqual(ErrorLines.lines(for: c, size: .medium), ["Claude: cswap not found"])
    }

    func testASingleProvidersErrorIsNotPrefixed() {
        let snapshot = UsageSnapshot(writtenAt: entry, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .error, error: "cswap not found", accounts: []),
        ])
        XCTAssertEqual(ErrorLines.lines(for: WidgetContent.make(snapshot: snapshot, at: entry), size: .medium),
                       ["cswap not found"])
    }

    /// A one-line account whose numbers are not current is dated: "as of"
    /// its last known time, in place of its note.
    func testACompactRowDatesNumbersThatAreNotCurrent() {
        func account(_ note: String?, lastKnown: Date?, rows: Bool = true) -> WidgetContent.Account {
            let row = UsageDisplay.row(for: UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 40), at: entry)
            return WidgetContent.Account(id: "codex", label: "Codex", active: false, rows: rows ? [row] : [], note: note,
                                         lastKnownAt: lastKnown, current: note == nil)
        }
        func trailing(_ a: WidgetContent.Account) -> String? {
            CompactAccountRow.trailingNote(for: a, now: entry, locale: english, timeZone: utc, calendar: calendar)
        }
        let fiveAgo = entry.addingTimeInterval(-5 * 3600)
        let today = trailing(account("No new reading", lastKnown: fiveAgo))
        XCTAssertEqual(today, TimeText.asOf(fiveAgo, relativeTo: entry, locale: english, timeZone: utc, calendar: calendar))
        XCTAssertTrue(today?.hasPrefix("as of 7:04") ?? false, String(describing: today))
        let yesterday = entry.addingTimeInterval(-26 * 3600)
        XCTAssertEqual(trailing(account("Log in again", lastKnown: yesterday)),
                       TimeText.asOf(yesterday, relativeTo: entry, locale: english, timeZone: utc, calendar: calendar))
        XCTAssertTrue(trailing(account("Log in again", lastKnown: yesterday))?.contains("Sep 26") ?? false)
        XCTAssertNil(trailing(account(nil, lastKnown: nil)), "current numbers need no note")
        XCTAssertEqual(trailing(account("Token expired", lastKnown: nil)), "Token expired", "no time known: the note")
    }

    /// The footer says "Refreshing…" while a press is answered, else "as of".
    func testTheFooterText() {
        XCTAssertEqual(AsOfLine.text(date: entry, footer: .refreshing, now: entry, locale: english, timeZone: utc,
                                     calendar: calendar), "Refreshing\u{2026}")
        XCTAssertEqual(AsOfLine.text(date: entry, footer: .none, now: entry, locale: english, timeZone: utc,
                                     calendar: calendar),
                       TimeText.asOf(entry, relativeTo: entry, locale: english, timeZone: utc, calendar: calendar))
        XCTAssertEqual(AsOfLine.text(date: nil, footer: .refreshing, now: entry, locale: english, timeZone: utc,
                                     calendar: calendar), "Refreshing\u{2026}")
        XCTAssertNil(AsOfLine.text(date: nil, footer: .none, now: entry, locale: english, timeZone: utc, calendar: calendar))
    }

    /// Whatever the cap, the footer is "Refreshing…" or the plain "as of":
    /// never a word about limits.
    func testNoFooterMentionsALimit() {
        for footer in [RefreshFooter.none, .refreshing] {
            for date in [entry, nil] {
                let text = AsOfLine.text(date: date, footer: footer, now: entry, locale: english, timeZone: utc,
                                         calendar: calendar) ?? ""
                XCTAssertFalse(text.lowercased().contains("limit"), text)
            }
        }
    }

    func testVoiceOverNamesTheCodexPlanAndResets() throws {
        let codex = try XCTUnwrap(content().sections.last?.accounts.first)
        XCTAssertEqual(Accessibility.header(for: codex), "Codex, Pro plan, 2 resets available")
        XCTAssertEqual(Accessibility.label(for: codex, locale: english, timeZone: utc, calendar: calendar, now: entry),
                       "Codex, Pro plan. Weekly 35 percent. 2 resets available")
        let claude = try XCTUnwrap(content().sections.first?.accounts.first)
        XCTAssertEqual(Accessibility.header(for: claude), "Account 1, 1@example.com, active")
        XCTAssertEqual(Accessibility.label(for: claude, locale: english, timeZone: utc, calendar: calendar, now: entry),
                       "Account 1, 1@example.com. active. 7 day 10 percent")
    }
}
