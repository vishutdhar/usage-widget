import XCTest
@testable import UsageCore

final class UsageDisplayTests: XCTestCase {
    let now = utc(2026, 9, 27, 12, 0, 0)

    func testDisplayedPercentRoundsHalfToEvenLikeCswap() {
        XCTAssertEqual(UsageDisplay.displayedPercent(22.4), 22)
        XCTAssertEqual(UsageDisplay.displayedPercent(22.5), 22)
        XCTAssertEqual(UsageDisplay.displayedPercent(23.5), 24)
        XCTAssertEqual(UsageDisplay.displayedPercent(99.6), 100)
        XCTAssertEqual(UsageDisplay.displayedPercent(-3), 0)
    }

    func testPercentTextKeepsValuesOverOneHundred() {
        XCTAssertEqual(UsageDisplay.percentText(22), "22%")
        XCTAssertEqual(UsageDisplay.percentText(104), "104%")
    }

    func testFillFractionClampsAboveOneHundred() {
        XCTAssertEqual(UsageDisplay.fillFraction(130), 1)
        XCTAssertEqual(UsageDisplay.fillFraction(100), 1)
        XCTAssertEqual(UsageDisplay.fillFraction(50), 0.5)
        XCTAssertEqual(UsageDisplay.fillFraction(0), 0)
        XCTAssertEqual(UsageDisplay.fillFraction(-5), 0)
    }

    func testPaceTickOnlyOnWeeklyAndModelWindowsWithExpectedPct() {
        let weekly = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 80, expectedPct: 70)
        XCTAssertEqual(try XCTUnwrap(UsageDisplay.paceFraction(for: weekly)), 0.7, accuracy: 1e-9)

        let model = UsageWindow(kind: .model, name: "Fable", windowSeconds: 604_800, usedPct: 100, expectedPct: 40)
        XCTAssertEqual(try XCTUnwrap(UsageDisplay.paceFraction(for: model)), 0.4, accuracy: 1e-9)

        let noPace = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 80)
        XCTAssertNil(UsageDisplay.paceFraction(for: noPace))

        let session = UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 20, expectedPct: 40)
        XCTAssertNil(UsageDisplay.paceFraction(for: session), "the 5h window never gets a tick")
    }

    func testPaceTickIsClamped() {
        let over = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 1, expectedPct: 130)
        XCTAssertEqual(UsageDisplay.paceFraction(for: over), 1)
        let under = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 1, expectedPct: -2)
        XCTAssertEqual(UsageDisplay.paceFraction(for: under), 0)
    }

    func testFutureResetIsUnchanged() {
        let window = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 82,
                                 resetsAt: now.addingTimeInterval(60), expectedPct: 80, aheadOfPace: false)
        XCTAssertEqual(UsageDisplay.current(window, at: now), window)
    }

    func testPassedSessionResetReadsZeroWithNoReset() {
        let window = UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 64,
                                 resetsAt: now.addingTimeInterval(-1))
        let current = UsageDisplay.current(window, at: now)
        XCTAssertEqual(current.usedPct, 0)
        XCTAssertNil(current.resetsAt, "a new session window starts only when it is used")
    }

    func testResetExactlyNowCountsAsPassed() {
        let window = UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 64, resetsAt: now)
        XCTAssertEqual(UsageDisplay.current(window, at: now).usedPct, 0)
    }

    func testPassedWeeklyResetRollsForwardByWholeWeeks() {
        let reset = now.addingTimeInterval(-3600)
        let window = UsageWindow(kind: .model, name: "Fable", windowSeconds: 604_800, usedPct: 100,
                                 resetsAt: reset, expectedPct: 99, aheadOfPace: true)
        let current = UsageDisplay.current(window, at: now)
        XCTAssertEqual(current.usedPct, 0)
        XCTAssertEqual(current.resetsAt, reset.addingTimeInterval(604_800))
        XCTAssertNil(current.expectedPct, "a rolled window has no pace")
        XCTAssertNil(current.aheadOfPace)

        let eightDaysAgo = now.addingTimeInterval(-8 * 86_400)
        let old = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 50, resetsAt: eightDaysAgo)
        XCTAssertEqual(UsageDisplay.current(old, at: now).resetsAt, eightDaysAgo.addingTimeInterval(2 * 604_800))
    }

    func testRowCombinesEverything() {
        let window = UsageWindow(kind: .model, name: "Fable", windowSeconds: 604_800, usedPct: 104,
                                 resetsAt: now.addingTimeInterval(3600), expectedPct: 50, aheadOfPace: true)
        let row = UsageDisplay.row(for: window, at: now)
        XCTAssertEqual(row.label, "Fable")
        XCTAssertEqual(row.kind, .model)
        XCTAssertEqual(row.usedPct, 104)
        XCTAssertEqual(row.fraction, 1)
        XCTAssertEqual(row.percentText, "104%")
        XCTAssertEqual(row.level, .over)
        XCTAssertEqual(row.paceFraction, 0.5)
        XCTAssertEqual(row.resetsAt, now.addingTimeInterval(3600))
        XCTAssertTrue(row.overMarker)
        XCTAssertFalse(row.aheadOfPace, "over the limit, the (!) marker replaces the ahead signal, as in the menu")
    }

    func testAheadOfPaceBelowTheLimit() {
        let window = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 95,
                                 resetsAt: now.addingTimeInterval(3600), expectedPct: 50, aheadOfPace: true)
        XCTAssertTrue(UsageDisplay.row(for: window, at: now).aheadOfPace)
    }

    func testRowOfRolledWindowHasNoTickAndNoMarker() {
        let window = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 100,
                                 resetsAt: now.addingTimeInterval(-60), expectedPct: 99, aheadOfPace: true)
        let row = UsageDisplay.row(for: window, at: now)
        XCTAssertEqual(row.percentText, "0%")
        XCTAssertEqual(row.level, .ok)
        XCTAssertNil(row.paceFraction)
        XCTAssertFalse(row.overMarker)
        XCTAssertFalse(row.aheadOfPace)
    }

    func testRowLevelUsesTheReportedNumber() {
        let window = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 89.6)
        let row = UsageDisplay.row(for: window, at: now)
        XCTAssertEqual(row.percentText, "90%")
        XCTAssertEqual(row.level, .warn, "the band follows cswap: 89.6 is below 90 even though it reads 90%")
    }
}
