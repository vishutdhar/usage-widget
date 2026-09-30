import XCTest
@testable import UsageCore

final class TimelinePlanTests: XCTestCase {
    /// On a 5 minute boundary, so bucket ends are easy to read.
    let now = utc(2026, 9, 27, 12, 0, 0)

    func minutes(_ m: Double) -> Date { now.addingTimeInterval(m * 60) }

    func snapshot(resets: [Date?], fetchedAt: Date? = nil, status: AccountUsage.Status = .ok) -> UsageSnapshot {
        let windows = resets.enumerated().map { index, reset in
            UsageWindow(kind: .weekly, name: "w\(index)", windowSeconds: 604_800, usedPct: 10, resetsAt: reset)
        }
        return UsageSnapshot(writtenAt: now, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                AccountUsage(id: "1", label: "a", active: true, fetchedAt: fetchedAt, windows: windows,
                             status: status),
            ]),
        ])
    }

    func testReloadFloorIsThreeHours() {
        XCTAssertEqual(TimelinePlan.reloadFloor, 3 * 3600)
    }

    func testNoSnapshot() {
        XCTAssertEqual(TimelinePlan.plan(for: nil, now: now),
                       TimelinePlan.Plan(entries: [now], reloadAfter: minutes(180)))
    }

    func testBucketEndsRoundUp() {
        XCTAssertEqual(TimelinePlan.bucketEnd(minutes(5)), minutes(5), "a boundary is its own bucket end")
        XCTAssertEqual(TimelinePlan.bucketEnd(minutes(5).addingTimeInterval(1)), minutes(10))
        XCTAssertEqual(TimelinePlan.bucketEnd(minutes(9.99)), minutes(10))
    }

    func testUpcomingResetsInsideTheHorizonInOrder() {
        let s = snapshot(resets: [minutes(180), minutes(10), nil, minutes(-60), minutes(2 * 1440), minutes(10)])
        XCTAssertEqual(TimelinePlan.plan(for: s, now: now),
                       TimelinePlan.Plan(entries: [now, minutes(10), minutes(180)], reloadAfter: minutes(180)))
    }

    func testTenResetsASecondApartAreOneBucket() {
        let base = minutes(7)
        let s = snapshot(resets: (0..<10).map { base.addingTimeInterval(Double($0)) })
        XCTAssertEqual(TimelinePlan.plan(for: s, now: now).entries, [now, minutes(10)])
    }

    /// Buckets past the eighth are left to the next timeline. The policy
    /// stays at 3 hours even then, so the widget's own reloads never exceed
    /// 8 a day and the combined budget holds.
    func testTwelveBucketsKeepEightAndTheFloorStays() {
        for spacing in [5.0, 10.0] {
            let s = snapshot(resets: (1...12).map { minutes(Double($0) * spacing) })
            let plan = TimelinePlan.plan(for: s, now: now)
            XCTAssertEqual(plan.entries, [now] + (1...8).map { minutes(Double($0) * spacing) })
            XCTAssertEqual(plan.reloadAfter, minutes(180))
        }
    }

    func testTheTwoHourDimmingLineGetsAnEntryMergedIntoItsBucket() {
        // Measured 1 h 58 min ago: crosses the dimming line at minute 2,
        // which shares the 12:05 bucket with a reset at minute 3.
        let s = snapshot(resets: [minutes(3)], fetchedAt: minutes(-118))
        XCTAssertEqual(TimelinePlan.plan(for: s, now: now).entries, [now, minutes(5)])
        let alone = snapshot(resets: [nil], fetchedAt: minutes(-118))
        XCTAssertEqual(TimelinePlan.plan(for: alone, now: now).entries, [now, minutes(5)])
    }

    func testEveryStatusDimsSoEveryStatusGetsTheEntry() {
        let stale = snapshot(resets: [nil], fetchedAt: minutes(-118), status: .stale)
        XCTAssertEqual(TimelinePlan.plan(for: stale, now: now).entries, [now, minutes(5)])
    }

    func testNoDimmingEntryWhenAlreadyDimOrWithoutNumbers() {
        XCTAssertEqual(TimelinePlan.plan(for: snapshot(resets: [nil], fetchedAt: minutes(-180)), now: now).entries, [now],
                       "already past the line: this entry shows it")
        XCTAssertEqual(TimelinePlan.plan(for: snapshot(resets: [], fetchedAt: minutes(-118)), now: now).entries, [now],
                       "no numbers, nothing to dim")
    }

    /// Dimming crossings come first (the earliest three), then reset buckets
    /// fill the remaining slots, so eight early resets cannot push a dimming
    /// entry out.
    func testDimmingCrossingsOutrankResetBuckets() {
        let s = snapshot(resets: (1...8).map { minutes(Double($0) * 5) }, fetchedAt: minutes(-70))
        let plan = TimelinePlan.plan(for: s, now: now)
        XCTAssertEqual(plan.entries.count, 9)
        XCTAssertEqual(plan.entries, [now] + (1...7).map { minutes(Double($0) * 5) } + [minutes(55)],
                       "seven resets, then the crossing at 12:50:01 in the 12:55 bucket")
    }

    func crossingSnapshot(fetched offsets: [Double], resets: [Date] = []) -> UsageSnapshot {
        var accounts = offsets.enumerated().map { index, offset in
            AccountUsage(id: "\(index)", label: "a", active: index == 0, fetchedAt: minutes(offset),
                         windows: [UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 10)])
        }
        accounts[0].windows += resets.enumerated().map { index, reset in
            UsageWindow(kind: .model, name: "m\(index)", windowSeconds: 604_800, usedPct: 1, resetsAt: reset)
        }
        return UsageSnapshot(writtenAt: now, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: accounts),
        ])
    }

    /// Four crossings (12:05, 12:15, 12:25 and 12:35) and nothing competing:
    /// every one gets its entry.
    func testFourCrossingsWithFreeSlotsAllGetEntries() {
        let s = crossingSnapshot(fetched: [-119, -109, -99, -89])
        XCTAssertEqual(TimelinePlan.plan(for: s, now: now).entries,
                       [now, minutes(5), minutes(15), minutes(25), minutes(35)])
    }

    /// Crossings take priority up to the full eight slots.
    func testTenCrossingsFillAllEightSlotsBeforeAnyReset() {
        let s = crossingSnapshot(fetched: (0..<10).map { -119 + Double($0) * 5 },
                                 resets: [minutes(2), minutes(57), minutes(58)])
        XCTAssertEqual(TimelinePlan.plan(for: s, now: now).entries,
                       [now] + (1...8).map { minutes(Double($0) * 5) },
                       "the earliest eight crossings, 12:05 to 12:40; no reset displaces them")
    }
}
