import XCTest
@testable import UsageCore

/// Old numbers keep their colours and say they are old; a widget whose
/// agent has stopped says it is not updating.
final class StaleDisplayTests: XCTestCase {
    let zone = TimeZone(identifier: "UTC")!
    let english = Locale(identifier: "en_US")
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }
    let now = utc(2026, 1, 15, 11, 37, 0)

    func moment(_ date: Date) -> String {
        TimeText.moment(date, relativeTo: now, locale: english, timeZone: zone, calendar: calendar)
    }

    func testTimesFromYesterdaySayYesterday() {
        XCTAssertEqual(moment(utc(2026, 1, 15, 9, 5, 0)), "9:05\u{202F}AM")
        XCTAssertEqual(moment(utc(2026, 1, 14, 19, 8, 0)), "7:08\u{202F}PM yesterday")
        XCTAssertFalse(moment(utc(2026, 1, 13, 19, 8, 0)).contains("yesterday"))
        XCTAssertTrue(moment(utc(2026, 1, 13, 19, 8, 0)).contains("Jan 13"))
    }

    func testTheStaleLine() {
        XCTAssertEqual(TimeText.staleLine(since: utc(2026, 1, 14, 19, 8, 0), relativeTo: now, locale: english, timeZone: zone,
                                          calendar: calendar), "stale \u{00B7} as of 7:08\u{202F}PM yesterday")
    }

    func snapshot(fetched: Date, written: Date) -> UsageSnapshot {
        UsageSnapshot(writtenAt: written, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                AccountUsage(id: "1", label: "a@example.com", active: true, fetchedAt: fetched, windows: [
                    UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 80),
                ]),
            ]),
        ])
    }

    /// Numbers past their line are marked stale with their time; the bars
    /// are not recoloured (the flag stays data for the note).
    func testAnOldAccountIsMarkedStaleWithItsTime() throws {
        let fetched = now.addingTimeInterval(-3 * 3600)
        let account = try XCTUnwrap(WidgetContent.make(snapshot: snapshot(fetched: fetched, written: now), at: now)
            .sections.first?.accounts.first)
        XCTAssertEqual(account.staleSince, fetched)
        XCTAssertTrue(account.dimmed)
        XCTAssertEqual(account.rows.first?.level, .warn, "the usage colour stays")
        let fresh = try XCTUnwrap(WidgetContent.make(snapshot: snapshot(fetched: now.addingTimeInterval(-600), written: now),
                                                     at: now).sections.first?.accounts.first)
        XCTAssertNil(fresh.staleSince)
    }

    /// The agent rewrites the snapshot every minute. A snapshot already
    /// more than five minutes old when the widget reloads means the agent
    /// is not running: the footer says so.
    func testAWidgetWhoseAgentStoppedSaysItIsNotUpdating() {
        let old = WidgetContent.make(snapshot: snapshot(fetched: now, written: now.addingTimeInterval(-301)), at: now,
                                     refresh: nil, checkedAt: now)
        XCTAssertTrue(old.notUpdating)
        let live = WidgetContent.make(snapshot: snapshot(fetched: now, written: now.addingTimeInterval(-60)), at: now,
                                      refresh: nil, checkedAt: now)
        XCTAssertFalse(live.notUpdating)
        XCTAssertFalse(WidgetContent.make(snapshot: nil, at: now, refresh: nil, checkedAt: now).notUpdating,
                       "no snapshot has its own empty state")
    }

    /// The widget learns the agent stopped only when it reads the snapshot:
    /// between reads WidgetKit shows entries made at the last read, and the
    /// agent asks for a read only when the display changes (on a normal day
    /// most reads are more than 5 minutes apart). So no entry made at a
    /// healthy read says "Not updating", however far ahead it lies.
    func testEntriesOfAHealthyReadNeverSayNotUpdating() {
        let read = Date(timeIntervalSince1970: 1_790_000_000)
        let snapshot = UsageSnapshot(writtenAt: read.addingTimeInterval(-30), providers: [])
        let entries = WidgetContent.timelineEntries(for: snapshot, readAt: read, refresh: nil)
        XCTAssertGreaterThan(entries.count, 0)
        XCTAssertTrue(entries.allSatisfy { !$0.content.notUpdating })
        let far = WidgetContent.timelineEntries(for: snapshot, readAt: read, refresh: nil,
                                                 dates: [read.addingTimeInterval(2 * 3600)])
        XCTAssertFalse(far[0].content.notUpdating, "two hours on, a healthy agent has simply not asked for a read")
    }

    /// An agent that stops right after a healthy read shows at the next
    /// read, which the timeline's fallback brings within 3 hours.
    func testAStopAfterAHealthyReadShowsAtTheNextRead() {
        let read = Date(timeIntervalSince1970: 1_790_000_000)
        let snapshot = UsageSnapshot(writtenAt: read.addingTimeInterval(-30), providers: [])
        let plan = TimelinePlan.plan(for: snapshot, now: read, refresh: nil)
        XCTAssertLessThanOrEqual(plan.reloadAfter, read.addingTimeInterval(3 * 3600))
        let next = WidgetContent.timelineEntries(for: snapshot, readAt: plan.reloadAfter, refresh: nil)
        XCTAssertTrue(next.allSatisfy { $0.content.notUpdating })
    }
}
