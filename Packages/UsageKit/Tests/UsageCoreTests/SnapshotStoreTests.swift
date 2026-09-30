import XCTest
@testable import UsageCore

final class SnapshotStoreTests: XCTestCase {
    let t0 = utc(2026, 1, 15, 10, 0, 0)

    func sample() -> UsageSnapshot {
        UsageSnapshot(writtenAt: t0, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                AccountUsage(id: "1", label: "alex@example.com", active: true, fetchedAt: nil, windows: [
                    UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 0),
                    UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 80,
                                resetsAt: utc(2026, 1, 16, 19, 0, 0), expectedPct: 70, aheadOfPace: false),
                ]),
            ]),
        ])
    }

    func json(_ snapshot: UsageSnapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: SnapshotStore.encode(snapshot)) as? [String: Any])
    }

    func testTopLevelShape() throws {
        let object = try json(sample())
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "writtenAt", "providers"])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["writtenAt"] as? String, "2026-01-15T10:00:00.000Z")
    }

    func testOptionalFieldsAreExplicitNulls() throws {
        let provider = try XCTUnwrap((json(sample())["providers"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(provider.keys), ["provider", "source", "status", "error", "accounts", "extras", "collectorError", "hidden"])
        XCTAssertTrue(provider["error"] is NSNull)
        XCTAssertTrue(provider["collectorError"] is NSNull)
        XCTAssertEqual((provider["extras"] as? [String: Any])?.count, 0)

        let account = try XCTUnwrap((provider["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(account.keys), ["id", "label", "active", "fetchedAt", "windows", "status", "statusNote", "ageSeconds"])
        XCTAssertTrue(account["fetchedAt"] is NSNull)
        XCTAssertEqual(account["status"] as? String, "ok")
        XCTAssertTrue(account["statusNote"] is NSNull)
        XCTAssertTrue(account["ageSeconds"] is NSNull)

        let windows = try XCTUnwrap(account["windows"] as? [[String: Any]])
        XCTAssertEqual(Set(try windows[at: 0].keys),
                       ["kind", "name", "windowSeconds", "usedPct", "resetsAt", "expectedPct", "aheadOfPace",
                        "amount", "limit", "currency"])
        XCTAssertTrue(try windows[at: 0]["resetsAt"] is NSNull)
        XCTAssertTrue(try windows[at: 0]["expectedPct"] is NSNull)
        XCTAssertTrue(try windows[at: 0]["aheadOfPace"] is NSNull)
        XCTAssertEqual(try windows[at: 1]["resetsAt"] as? String, "2026-01-16T19:00:00.000Z")
        XCTAssertEqual(try windows[at: 1]["kind"] as? String, "weekly")
    }

    func testRoundTrip() throws {
        XCTAssertEqual(try SnapshotStore.decode(SnapshotStore.encode(sample())), sample())
    }

    func testReadWrite() throws {
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        XCTAssertNil(SnapshotStore.read(from: url), "missing file")
        try SnapshotStore.write(sample(), to: url)
        XCTAssertEqual(SnapshotStore.read(from: url), sample())
    }

    func testReadRejectsGarbageAndOtherSchemas() throws {
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        try Data("{".utf8).write(to: url)
        XCTAssertNil(SnapshotStore.read(from: url))

        var future = sample()
        future.schemaVersion = 2
        try SnapshotStore.write(future, to: url)
        XCTAssertNil(SnapshotStore.read(from: url))
    }

    func testSnapshotsWithoutTheAdditiveFieldsStillRead() throws {
        let text = """
        {"schemaVersion":1,"writtenAt":"2026-01-15T10:00:00Z","providers":[
          {"provider":"claude","source":"cswap-list","status":"ok","error":null,"extras":{},"accounts":[
            {"id":"1","label":"a","active":true,"fetchedAt":null,"windows":[
              {"kind":"weekly","name":"7d","windowSeconds":604800,"usedPct":5,"resetsAt":null,
               "expectedPct":null,"aheadOfPace":null}]}]}]}
        """
        let account = try SnapshotStore.decode(Data(text.utf8)).providers[at: 0].accounts[at: 0]
        XCTAssertEqual(account.status, .ok)
        XCTAssertNil(account.statusNote)
        XCTAssertNil(try account.windows[at: 0].amount)
    }

    func testMissingExtrasDecodesAsEmpty() throws {
        let text = """
        {"schemaVersion":1,"writtenAt":"2026-01-15T10:00:00Z","providers":[
          {"provider":"codex","source":"rollout","status":"ok","error":null,"accounts":[]}]}
        """
        let snapshot = try SnapshotStore.decode(Data(text.utf8))
        XCTAssertEqual(try snapshot.providers[at: 0].extras, [:])
    }
}
