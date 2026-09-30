import XCTest
@testable import UsageCore

final class MapperStatusTests: XCTestCase {
    func testEveryCswapStatusMapsToAnAccountStatusAndNote() throws {
        let accounts = try CswapListMapper.accounts(from: fixture("cswap-list-statuses"))
        let got = accounts.map { "\($0.id) \($0.status.rawValue) \($0.statusNote ?? "-")" }
        XCTAssertEqual(got, [
            "1 ok -",
            "2 relogin_required Log in again",
            "3 relogin_required No saved login",
            "4 stale Token expired",
            "5 unavailable Keychain locked",
            "6 unavailable Signed in as another account",
            "7 unavailable API key, no plan limits",
            "8 unavailable Usage unavailable (http-429)",
            "9 unavailable Usage unavailable",
            "10 unavailable Usage unavailable",
        ])
    }

    func testLastKnownNumbersKeepTheirOwnMeasurementTime() throws {
        let accounts = try CswapListMapper.accounts(from: fixture("cswap-list-statuses"))
        let relogin = try accounts[at: 1]
        XCTAssertEqual(relogin.windows.map(\.usedPct), [40])
        XCTAssertEqual(relogin.fetchedAt, utc(2026, 9, 26, 10, 0, 0))
        let stale = try accounts[at: 3]
        XCTAssertEqual(stale.windows.map(\.usedPct), [55])
        XCTAssertEqual(stale.fetchedAt, utc(2026, 9, 27, 8, 0, 0))
        XCTAssertNil(try accounts[at: 4].fetchedAt, "no numbers, no measurement time")
    }
}

final class MapperSpendTests: XCTestCase {
    func testSpendAlone() throws {
        let account = try CswapListMapper.accounts(from: fixture("cswap-list-spend"))[at: 0]
        XCTAssertEqual(account.windows.count, 1)
        let spend = try account.windows[at: 0]
        XCTAssertEqual(spend.kind, .spend)
        XCTAssertEqual(spend.name, "Spend")
        XCTAssertEqual(spend.windowSeconds, 0)
        XCTAssertEqual(spend.usedPct, 80)
        XCTAssertEqual(spend.amount, 80)
        XCTAssertEqual(spend.limit, 100)
        XCTAssertEqual(spend.currency, "USD")
        XCTAssertEqual(spend.resetsAt, utc(2026, 10, 1))
        XCTAssertNil(spend.expectedPct)
    }

    func testSpendComesLastLikeTheMenu() throws {
        let account = try CswapListMapper.accounts(from: fixture("cswap-list-spend"))[at: 1]
        XCTAssertEqual(account.windows.map(\.name), ["5h", "7d", "Fable", "Spend"])
        XCTAssertEqual(account.windows.map(\.kind), [.session, .weekly, .model, .spend])
        XCTAssertEqual(try account.windows[at: 3].currency, "EUR")
        XCTAssertNil(try account.windows[at: 3].resetsAt)
    }
}

final class MapperNumberTests: XCTestCase {
    func testOutOfRangePercentsBecomeUnknown() throws {
        let account = try CswapListMapper.accounts(from: fixture("cswap-list-numbers"))[at: 0]
        XCTAssertEqual(account.windows.map(\.name), ["5h", "7d", "Null", "Text", "Literal", "Inf", "Edge", "Over", "Spend"])
        XCTAssertEqual(account.windows.map(\.usedPct), [nil, 0, nil, nil, nil, nil, 10_000, nil, 12],
                       "1e20, null, a string, NaN and infinity are unknown; -5 is clamped to 0; 10,000 is the edge")
        XCTAssertNil(try account.windows[at: 1].expectedPct, "a NaN pace is dropped")
        XCTAssertNil(try account.windows[at: 8].amount, "an infinite amount is dropped")
    }
}

final class SnapshotValidatorTests: XCTestCase {
    let t0 = utc(2026, 9, 27, 10, 0, 0)

    func snapshot(_ windows: [UsageWindow]) -> UsageSnapshot {
        UsageSnapshot(writtenAt: t0, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                AccountUsage(id: "1", label: "a", active: true, fetchedAt: t0, windows: windows),
            ]),
        ])
    }

    func window(_ pct: Double?, expected: Double? = nil, amount: Double? = nil, seconds: Int = 604_800,
                reset: Date? = nil) -> UsageWindow {
        UsageWindow(kind: .weekly, name: "7d", windowSeconds: seconds, usedPct: pct, resetsAt: reset,
                    expectedPct: expected, amount: amount)
    }

    func testSanitizedReplacesUnusableNumbers() throws {
        let raw = snapshot([
            window(.nan), window(.infinity), window(1e20), window(-5), window(10_000), window(55),
            window(10, expected: .nan), window(10, expected: 130), window(10, amount: -.infinity),
            window(10, seconds: -60), window(10, reset: Date(timeIntervalSince1970: .nan)),
        ])
        let windows = try SnapshotValidator.sanitized(raw).providers[at: 0].accounts[at: 0].windows
        XCTAssertEqual(windows.map(\.usedPct), [nil, nil, nil, 0, 10_000, 55, 10, 10, 10, 10, 10])
        XCTAssertNil(try windows[at: 6].expectedPct)
        XCTAssertEqual(try windows[at: 7].expectedPct, 100)
        XCTAssertNil(try windows[at: 8].amount)
        XCTAssertEqual(try windows[at: 9].windowSeconds, 0)
        XCTAssertNil(try windows[at: 10].resetsAt)
    }

    func testWriteValidatesFirst() throws {
        let raw = snapshot([window(.nan), window(40)])
        XCTAssertThrowsError(try SnapshotStore.encode(raw), "JSON has no NaN; unvalidated it cannot be written")
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        try SnapshotStore.write(raw, to: url)
        let read = try XCTUnwrap(SnapshotStore.read(from: url))
        XCTAssertEqual(try read.providers[at: 0].accounts[at: 0].windows.map(\.usedPct), [nil, 40])
    }
}

final class NumberSafetyTests: XCTestCase {
    func testDisplayedPercentNeverTraps() {
        XCTAssertEqual(UsageDisplay.displayedPercent(1e20), 10_000)
        XCTAssertEqual(UsageDisplay.displayedPercent(.infinity), 10_000)
        XCTAssertEqual(UsageDisplay.displayedPercent(.nan), 0)
        XCTAssertEqual(UsageDisplay.displayedPercent(-.infinity), 0)
    }

    func testUnknownRowHasNoBarAndAQuestionMark() {
        let window = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: nil, expectedPct: 50)
        let row = UsageDisplay.row(for: window, at: utc(2026, 9, 27))
        XCTAssertEqual(row.percentText, "?")
        XCTAssertEqual(row.level, .unknown)
        XCTAssertEqual(row.fraction, 0)
        XCTAssertNil(row.paceFraction)
        XCTAssertFalse(row.overMarker)
        XCTAssertNil(UsageDisplay.paceFraction(for: window), "no tick against an unknown value")
    }

    func testFormattingAnUnusableDateNeverTraps() {
        XCTAssertEqual(ISODate.format(Date(timeIntervalSince1970: .nan)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(ISODate.format(Date(timeIntervalSince1970: .infinity)), "1970-01-01T00:00:00.000Z")
    }

    func testDimmingNeverTraps() {
        XCTAssertTrue(Staleness.isDimmed(fetchedAt: Date(timeIntervalSinceReferenceDate: -1e15), at: utc(2026, 9, 27), provider: "claude"))
        XCTAssertFalse(Staleness.isDimmed(fetchedAt: Date(timeIntervalSinceReferenceDate: .nan), at: utc(2026, 9, 27), provider: "claude"))
    }
}

final class SpendDisplayTests: XCTestCase {
    let now = utc(2026, 9, 27)
    let english = Locale(identifier: "en_US")

    func testSpendRowShowsAmountOfLimitInsteadOfACountdown() {
        let window = UsageWindow(kind: .spend, name: "Spend", windowSeconds: 0, usedPct: 80,
                                 resetsAt: now.addingTimeInterval(86_400), amount: 80, limit: 100, currency: "USD")
        let row = UsageDisplay.row(for: window, at: now)
        XCTAssertEqual(row.spend, SpendFigures(amount: 80, limit: 100, currency: "USD"))
        XCTAssertEqual(row.percentText, "80%")
        XCTAssertEqual(row.fraction, 0.8)
        XCTAssertNil(row.paceFraction)
    }

    func testSpendKeepsCentsWhenThereAreCents() {
        XCTAssertEqual(UsageDisplay.spendText(amount: 12.5, limit: 50, currency: "EUR", locale: english), "€12.50 of €50")
        XCTAssertNil(UsageDisplay.spendText(amount: nil, limit: 50, currency: "USD", locale: english))
    }

    func testOtherRowsHaveNoDetailText() {
        let window = UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 10)
        XCTAssertNil(UsageDisplay.row(for: window, at: now).spend)
    }
}
