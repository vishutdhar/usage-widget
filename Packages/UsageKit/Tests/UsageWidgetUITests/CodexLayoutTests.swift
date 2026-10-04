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
        XCTAssertEqual(candidates.last, LargeLayout.Candidate(shown: 2, rowLimit: 2, dense: true, compactOthers: true))
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
    /// The footer speaks for the Claude rows: an older Codex reading (its
    /// app-server is asked at most eight times a day) does not drag it back;
    /// the Codex row carries its own time instead, so no number is shown as
    /// newer than it is (issue #11: Claude 7:03 PM, Codex 5:24 PM, footer
    /// "as of 5:24 PM").
    func testAnOlderCodexReadingCarriesItsOwnTime() {
        let older = entry.addingTimeInterval(-100 * 60)
        let c = content(codexMeasured: older)
        XCTAssertEqual(MediumLayout.asOf(in: c, visibleOthers: 0), entry)
        XCTAssertEqual(MediumLayout.asOf(in: c, visibleOthers: 1), entry)
        XCTAssertEqual(LargeLayout.asOf(in: c, shown: 4), entry)
        XCTAssertEqual(LargeLayout.asOf(in: c, shown: 1), entry)
        let marked = c.markingOwnTimes(footer: entry)
        let codex = try! XCTUnwrap(marked.otherProviderAccounts.first)
        XCTAssertEqual(codex.ownTime, older)
        XCTAssertEqual(NoteRow.line(for: codex, now: entry, locale: english, timeZone: utc, calendar: calendar),
                       TimeText.asOf(older, relativeTo: entry, locale: english, timeZone: utc, calendar: calendar))
        XCTAssertEqual(CompactAccountRow.trailingNote(for: codex, now: entry, locale: english, timeZone: utc,
                                                      calendar: calendar),
                       TimeText.asOf(older, relativeTo: entry, locale: english, timeZone: utc, calendar: calendar))
        XCTAssertTrue(marked.sections[0].accounts.allSatisfy { $0.ownTime == nil }, "the footer speaks for these")
        // Every number on screen: no newer than the footer says, or dated itself.
        for account in marked.sections.flatMap(\.accounts) {
            XCTAssertTrue((account.measuredAt.map { $0 >= entry } ?? true) || account.ownTime != nil
                          || account.staleSince != nil || account.note != nil, account.id)
        }
        // A Codex reading as new as the footer needs no line of its own.
        XCTAssertNil(content().markingOwnTimes(footer: entry).otherProviderAccounts.first?.ownTime)
    }

    /// Every layout either size may pick dates the older Codex reading,
    /// including those that move stale marks into the headers: the stale
    /// line moves, the Codex "as of" line stays.
    func testEveryLayoutDatesAnOlderCodexReading() {
        let older = entry.addingTimeInterval(-100 * 60)
        let c = content(codexMeasured: older)
        for candidate in LargeLayout.candidates(in: c) {
            let laid = LargeLayout(content: c, candidate: candidate).content
            XCTAssertEqual(laid.otherProviderAccounts.first?.ownTime, older, "\(candidate)")
        }
        for candidate in MediumLayout.candidates(in: c) {
            let laid = MediumLayout(content: c, candidate: candidate).content
            XCTAssertEqual(laid.otherProviderAccounts.first?.ownTime, older, "\(candidate)")
        }
        let codex = c.markingOwnTimes(footer: entry).otherProviderAccounts.first!
        XCTAssertEqual(NoteRow.shownLine(for: codex, staleInHeader: true, now: entry, locale: english, timeZone: utc,
                                         calendar: calendar),
                       TimeText.asOf(older, relativeTo: entry, locale: english, timeZone: utc, calendar: calendar))
        var stale = c.sections[0].accounts[0]
        stale.staleSince = older
        XCTAssertNil(NoteRow.shownLine(for: stale, staleInHeader: true, now: entry, locale: english, timeZone: utc,
                                       calendar: calendar), "the stale mark is in the header")
        XCTAssertNotNil(NoteRow.shownLine(for: stale, staleInHeader: false, now: entry, locale: english, timeZone: utc,
                                          calendar: calendar))
        var noted = codex
        noted.ownTime = nil
        noted.note = "No new reading"
        noted.lastKnownAt = older
        XCTAssertEqual(NoteRow.shownLine(for: noted, staleInHeader: true, now: entry, locale: english, timeZone: utc,
                                         calendar: calendar),
                       TimeText.noteLine("No new reading", lastKnownAt: older, relativeTo: entry, locale: english,
                                         timeZone: utc, calendar: calendar), "a note keeps its line and its time")
    }

    /// Each layout dates against its own footer: Claude A at noon, B at 10:00,
    /// Codex at 11:00. Showing B, the footer is 10:00 and Codex needs no
    /// line; leaving B out, the footer is noon and Codex says "as of 11:00".
    func testEachLayoutDatesAgainstItsOwnFooter() {
        let noon = entry, ten = entry.addingTimeInterval(-2 * 3600), eleven = entry.addingTimeInterval(-3600)
        func claude(_ id: String, _ measured: Date) -> AccountUsage {
            AccountUsage(id: id, label: "\(id)@example.com", active: id == "1", fetchedAt: measured, windows: [
                UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 10),
            ])
        }
        let snapshot = UsageSnapshot(writtenAt: entry, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok,
                          accounts: [claude("1", noon), claude("2", ten)]),
            ProviderUsage(provider: "codex", source: "rollout", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: eleven, windows: [
                    UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 35),
                ]),
            ]),
        ])
        let c = WidgetContent.make(snapshot: snapshot, at: entry)
        XCTAssertEqual(LargeLayout.asOf(in: c, shown: 3), ten)
        XCTAssertNil(LargeLayout(content: c, candidate: .init(shown: 3)).content.otherProviderAccounts.first?.ownTime)
        XCTAssertEqual(LargeLayout.asOf(in: c, shown: 2), noon)
        XCTAssertEqual(LargeLayout(content: c, candidate: .init(shown: 2)).content.otherProviderAccounts.first?.ownTime,
                       eleven)
        XCTAssertEqual(MediumLayout.asOf(in: c, visibleOthers: 1), noon)
        XCTAssertEqual(MediumLayout(content: c, visibleOthers: 1).content.otherProviderAccounts.first?.ownTime, eleven)
        XCTAssertEqual(MediumLayout.asOf(in: c, visibleOthers: 2), ten)
        XCTAssertNil(MediumLayout(content: c, visibleOthers: 2).content.otherProviderAccounts.first?.ownTime)
        // Spoken too: the Codex row's label carries its own time.
        let codex = MediumLayout(content: c, visibleOthers: 1).content.otherProviderAccounts.first!
        XCTAssertTrue(Accessibility.label(for: codex, locale: english, timeZone: utc, calendar: calendar, now: entry)
            .contains(TimeText.asOf(eleven, relativeTo: entry, locale: english, timeZone: utc, calendar: calendar)))
    }

    /// With no cswap numbers on screen, the footer falls back to the others..
    func testWithoutCswapNumbersTheFooterIsTheOthers() {
        let older = entry.addingTimeInterval(-100 * 60)
        let snapshot = UsageSnapshot(writtenAt: entry, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .error, error: "cswap not found", accounts: [
                AccountUsage(id: "1", label: "a@example.com", active: true, fetchedAt: entry, windows: []),
            ]),
            ProviderUsage(provider: "codex", source: "rollout", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: older, windows: [
                    UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 35),
                ]),
            ]),
        ])
        let c = WidgetContent.make(snapshot: snapshot, at: entry)
        XCTAssertEqual(LargeLayout.asOf(in: c, shown: 2), older)
        XCTAssertNil(c.markingOwnTimes(footer: older).otherProviderAccounts.first?.ownTime)
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
        XCTAssertTrue(trailing(account("Log in again", lastKnown: yesterday))?.hasSuffix("yesterday") ?? false)
        let twoDays = entry.addingTimeInterval(-50 * 3600)
        XCTAssertTrue(trailing(account("Log in again", lastKnown: twoDays))?.contains("Sep 25") ?? false)
        XCTAssertNil(trailing(account(nil, lastKnown: nil)), "current numbers need no note")
        var stale = account(nil, lastKnown: nil)
        stale.staleSince = fiveAgo
        XCTAssertEqual(trailing(stale), TimeText.staleTag(since: fiveAgo, relativeTo: entry, locale: english, timeZone: utc,
                                                          calendar: calendar), "current but old numbers say stale, briefly")
        XCTAssertEqual(trailing(account("Token expired", lastKnown: nil)), "Token expired", "no time known: the note")
    }

    /// The footer says "Refreshing…" while a press is answered, else "as of".
    /// A widget whose agent stopped says so, unless a press is being
    /// answered.
    func testTheNotUpdatingFooter() {
        XCTAssertEqual(AsOfLine.text(date: entry, footer: .none, now: entry, locale: english, timeZone: utc,
                                     calendar: calendar, notUpdating: true), "Not updating; open Usage Widget")
        XCTAssertEqual(AsOfLine.text(date: entry, footer: .refreshing, now: entry, locale: english, timeZone: utc,
                                     calendar: calendar, notUpdating: true), "Refreshing\u{2026}")
    }

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

    /// Short of height, the large widget gives up, in order: roomy spacing,
    /// the stale line (moved into the header), rows past the two that
    /// matter; only then an account, never the active one.
    func testTheLargeLadderKeepsEveryAccountUntilRowsAreCutToTwo() throws {
        let accounts = (1...3).map { i in
            AccountUsage(id: "\(i)", label: "a\(i)@example.com", active: i == 1, fetchedAt: entry.addingTimeInterval(-3 * 3600),
                         windows: [UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 10),
                                   UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 50),
                                   UsageWindow(kind: .model, name: "Fable", windowSeconds: 604_800, usedPct: 90)])
        }
        let snapshot = UsageSnapshot(writtenAt: entry.addingTimeInterval(-60), providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: accounts),
            ProviderUsage(provider: "codex", source: "app-server", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: entry,
                             windows: [UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 30)]),
            ]),
        ])
        let content = WidgetContent.make(snapshot: snapshot, at: entry)
        let candidates = LargeLayout.candidates(in: content)
        let all = 4
        let firstDrop = try XCTUnwrap(candidates.firstIndex { $0.shown < all })
        let before = candidates[..<firstDrop]
        XCTAssertTrue(before.contains { $0.dense && !$0.staleInHeader && $0.rowLimit == .max })
        XCTAssertTrue(before.contains { $0.dense && $0.staleInHeader && $0.rowLimit == .max })
        XCTAssertTrue(before.contains { $0.dense && $0.staleInHeader && $0.rowLimit == 2 })
        let order = before.map { [$0.dense ? 1 : 0, $0.staleInHeader ? 1 : 0, $0.rowLimit == 2 ? 1 : 0] }
        XCTAssertEqual(order, order.sorted { $0.lexicographicallyPrecedes($1) }, "each step gives up more than the last")
    }

    /// A stale mark in the header takes the place of "active" (the accent
    /// dot still marks the active account, and VoiceOver still says it).
    func testTheHeaderStaleTagTakesThePlaceOfActive() {
        let active = WidgetContent.Account(id: "1", label: "a@example.com", active: true, rows: [], note: nil)
        XCTAssertEqual(AccountHeader.rightSide(of: active, tag: nil), ["active"])
        XCTAssertEqual(AccountHeader.rightSide(of: active, tag: "stale 5:30 AM"), ["stale 5:30 AM"])
        var codex = WidgetContent.Account(id: "codex", label: "Codex", active: false, rows: [], note: nil)
        codex.footnote = "1 reset available"
        XCTAssertEqual(AccountHeader.rightSide(of: codex, tag: "stale 5:30 AM"), ["1 reset available", "stale 5:30 AM"])
        XCTAssertEqual(Accessibility.header(for: active, staleTag: "stale 5:30 AM"), "Account 1, a@example.com, stale 5:30 AM, active")
    }
}
