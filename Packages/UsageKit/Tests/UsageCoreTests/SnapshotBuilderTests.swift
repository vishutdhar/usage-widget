import XCTest
@testable import UsageCore

final class SnapshotBuilderTests: XCTestCase {
    let t0 = utc(2026, 9, 27, 10, 0, 0)
    let t1 = utc(2026, 9, 27, 10, 1, 0)

    func account(_ id: String, pct: Double, fetchedAt: Date) -> AccountUsage {
        AccountUsage(id: id, label: "\(id)@example.com", active: id == "1", fetchedAt: fetchedAt, windows: [
            UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: pct),
        ])
    }

    func build(_ previous: UsageSnapshot?, _ outcome: Result<[AccountUsage], FetchFailure>, at now: Date) -> UsageSnapshot {
        SnapshotBuilder.updating(previous, provider: "claude", source: "cswap-list", outcome: outcome, now: now)
    }

    func testSuccessFromNothing() {
        let accounts = [account("1", pct: 10, fetchedAt: t0)]
        let snapshot = build(nil, .success(accounts), at: t1)
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.writtenAt, t1)
        XCTAssertEqual(snapshot.providers, [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, error: nil, accounts: accounts, extras: [:]),
        ])
    }

    func testFailureKeepsLastGoodAccountsWithTheirFetchTimes() throws {
        let good = [account("1", pct: 10, fetchedAt: t0), account("2", pct: 90, fetchedAt: t0)]
        let first = build(nil, .success(good), at: t0)
        let failed = build(first, .failure(FetchFailure(reason: "cswap not found")), at: t1)
        XCTAssertEqual(failed.writtenAt, t1)
        let provider = try failed.providers[at: 0]
        XCTAssertEqual(provider.status, .error)
        XCTAssertEqual(provider.error, "cswap not found")
        XCTAssertEqual(provider.accounts, good)
        XCTAssertEqual(provider.accounts.map(\.fetchedAt), [t0, t0])
    }

    func testFailureAfterFailureStillKeepsTheLastGoodAccounts() {
        let good = [account("1", pct: 10, fetchedAt: t0)]
        let first = build(nil, .success(good), at: t0)
        let failed = build(first, .failure(FetchFailure(reason: "a")), at: t1)
        let again = build(failed, .failure(FetchFailure(reason: "b")), at: t1.addingTimeInterval(60))
        XCTAssertEqual(try again.providers[at: 0].accounts, good)
        XCTAssertEqual(try again.providers[at: 0].error, "b")
    }

    func testFailureWithNothingBeforeHasNoAccounts() {
        let snapshot = build(nil, .failure(FetchFailure(reason: "cswap not found")), at: t1)
        XCTAssertEqual(try snapshot.providers[at: 0].status, .error)
        XCTAssertEqual(try snapshot.providers[at: 0].accounts, [])
    }

    func testSuccessClearsTheError() {
        let failed = build(nil, .failure(FetchFailure(reason: "x")), at: t0)
        let ok = build(failed, .success([account("1", pct: 5, fetchedAt: t1)]), at: t1)
        XCTAssertEqual(try ok.providers[at: 0].status, .ok)
        XCTAssertNil(try ok.providers[at: 0].error)
    }

    func testOtherProvidersPassThroughInOrder() {
        let codex = ProviderUsage(provider: "codex", source: "rollout", status: .ok,
                                  accounts: [account("c", pct: 40, fetchedAt: t0)], extras: ["plan": .string("pro")])
        let previous = UsageSnapshot(writtenAt: t0, providers: [codex])
        let next = build(previous, .success([account("1", pct: 5, fetchedAt: t1)]), at: t1)
        XCTAssertEqual(next.providers.map(\.provider), ["codex", "claude"])
        XCTAssertEqual(try next.providers[at: 0], codex)
    }
}
