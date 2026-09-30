import XCTest
@testable import UsageCore

final class CswapListMapperTests: XCTestCase {
    func testSampleFixtureMapsEveryAccount() throws {
        let accounts = try CswapListMapper.accounts(from: fixture("cswap-list-sample"))
        XCTAssertEqual(accounts.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(accounts.map(\.label), ["alex@example.com", "sam@example.com", "jordan@example.com"])
        XCTAssertEqual(accounts.map(\.active), [true, false, false])
        XCTAssertEqual(accounts.map(\.status), [.ok, .ok, .ok])
        XCTAssertEqual(accounts.map(\.fetchedAt), [
            utc(2026, 1, 15, 10, 0, 0), utc(2026, 1, 15, 10, 0, 0), utc(2026, 1, 15, 9, 58, 0),
        ])
    }

    func testSampleFixtureMapsWindowsInMenuOrder() throws {
        let first = try CswapListMapper.accounts(from: fixture("cswap-list-sample"))[at: 0]
        XCTAssertEqual(first.windows.map(\.name), ["5h", "7d", "Fable"])
        XCTAssertEqual(first.windows.map(\.kind), [.session, .weekly, .model])
        XCTAssertEqual(first.windows.map(\.windowSeconds), [18_000, 604_800, 604_800])
        XCTAssertEqual(first.windows.map(\.usedPct), [20, 80, 100])

        let five = try first.windows[at: 0]
        let expectedReset = utc(2026, 1, 15, 14, 0, 0)
        XCTAssertEqual(try XCTUnwrap(five.resetsAt).timeIntervalSince1970, expectedReset.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(five.expectedPct, "the 5h window never carries pace")
        XCTAssertNil(five.aheadOfPace)

        let seven = try first.windows[at: 1]
        XCTAssertEqual(seven.expectedPct, 70)
        XCTAssertEqual(seven.aheadOfPace, false)
        XCTAssertEqual(try first.windows[at: 2].aheadOfPace, true)
    }

    func testFiveHourWindowWithOnlyPercentHasNoReset() throws {
        let second = try CswapListMapper.accounts(from: fixture("cswap-list-sample"))[at: 1]
        let five = try second.windows[at: 0]
        XCTAssertEqual(five.kind, .session)
        XCTAssertEqual(five.usedPct, 0)
        XCTAssertNil(five.resetsAt)
    }

    func testPartialWindowsAndMissingReset() throws {
        let accounts = try CswapListMapper.accounts(from: fixture("cswap-list-partial"))
        XCTAssertEqual(try accounts[at: 0].windows.map(\.name), ["7d"], "only the windows cswap reported")
        XCTAssertEqual(try accounts[at: 0].active, false)

        XCTAssertEqual(try accounts[at: 1].active, true, "activeAccountNumber marks the active slot when `active` is absent")
        XCTAssertEqual(try accounts[at: 1].windows.map(\.name), ["5h", "7d"])
        let seven = try accounts[at: 1].windows[at: 1]
        XCTAssertEqual(seven.usedPct, 12)
        XCTAssertNil(seven.resetsAt)
        XCTAssertNil(seven.expectedPct)
        XCTAssertNil(seven.aheadOfPace)
    }

    func testScopedModelWindowsAndAlias() throws {
        let account = try CswapListMapper.accounts(from: fixture("cswap-list-scoped"))[at: 0]
        XCTAssertEqual(account.label, "work", "an alias wins over the email")
        XCTAssertEqual(account.windows.map(\.name), ["5h", "7d", "Fable", "Opus"], "an unnamed scoped window is skipped, as in the menu")
        XCTAssertEqual(account.windows.map(\.kind), [.session, .weekly, .model, .model])
        XCTAssertEqual(try account.windows[at: 2].usedPct, 104, "the reported percent is kept; views clamp the bar")
        XCTAssertNil(try account.windows[at: 3].expectedPct)
    }

    func testUnavailableUsageFallsBackToLastGood() throws {
        let accounts = try CswapListMapper.accounts(from: fixture("cswap-list-unavailable"))
        XCTAssertEqual(try accounts[at: 0].windows.map(\.name), ["5h", "7d"])
        XCTAssertEqual(try accounts[at: 0].windows.map(\.usedPct), [7, 58])
        XCTAssertEqual(try accounts[at: 0].fetchedAt, utc(2026, 1, 15, 9, 15, 0), "last good data keeps its own measurement time")

        XCTAssertEqual(try accounts[at: 0].status, .stale, "failed fetch, last good numbers shown")
        XCTAssertEqual(try accounts[at: 0].statusNote, "Usage unavailable (http-429)")

        XCTAssertEqual(try accounts[at: 1].windows, [], "token expired with nothing last good: no windows")
        XCTAssertNil(try accounts[at: 1].fetchedAt)
        XCTAssertEqual(try accounts[at: 1].status, .unavailable)

        XCTAssertEqual(try accounts[at: 2].active, true)
        XCTAssertEqual(try accounts[at: 2].windows, [])
        XCTAssertEqual(try accounts[at: 2].status, .unavailable)
    }

    func testErrorEnvelopeIsReported() throws {
        XCTAssertThrowsError(try CswapListMapper.accounts(from: fixture("cswap-error-envelope"))) { error in
            XCTAssertEqual(error as? CswapListError, .reported("No accounts are managed yet. Run 'cswap add' first."))
        }
    }

    func testUnknownSchemaIsRejected() throws {
        XCTAssertThrowsError(try CswapListMapper.accounts(from: fixture("cswap-list-schema2"))) { error in
            XCTAssertEqual(error as? CswapListError, .unsupportedSchema(2))
        }
    }

    func testGarbageIsUnreadable() {
        for text in ["not json", "{\"schemaVersion\": 1}", "[]", ""] {
            XCTAssertThrowsError(try CswapListMapper.accounts(from: Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? CswapListError, .unreadable, text)
            }
        }
    }
}
