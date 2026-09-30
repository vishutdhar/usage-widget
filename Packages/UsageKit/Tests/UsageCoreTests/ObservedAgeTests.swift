import XCTest
@testable import UsageCore

/// A Codex reading's age is kept on the continuous clock by the agent and
/// written into the snapshot; the widget ages it from there by the time
/// since the write, so a wall clock jump neither dims fresh numbers nor
/// freshens stale ones.
final class ObservedAgeTests: XCTestCase {
    let written = utc(2026, 1, 15, 12, 0, 0)

    func codexSnapshot(fetchedAt: Date, age: Double?) -> UsageSnapshot {
        var account = AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: fetchedAt, windows: [
            UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 35),
        ])
        account.ageSeconds = age
        return UsageSnapshot(writtenAt: written, providers: [
            ProviderUsage(provider: "codex", source: "rollout", status: .ok, accounts: [account]),
        ])
    }

    func dimmed(_ snapshot: UsageSnapshot, at date: Date) -> Bool {
        WidgetContent.make(snapshot: snapshot, at: date).sections[0].accounts[0].dimmed
    }

    /// The wall clock jumped five hours ahead: the measurement time looks
    /// five hours old, but the numbers are ten minutes old.
    func testAJumpForwardDoesNotDimFreshNumbers() {
        let snapshot = codexSnapshot(fetchedAt: written.addingTimeInterval(-5 * 3600 - 600), age: 600)
        XCTAssertFalse(dimmed(snapshot, at: written))
        XCTAssertFalse(dimmed(snapshot, at: written.addingTimeInterval(3 * 3600 + 49 * 60)), "3 h 59 min old")
        XCTAssertTrue(dimmed(snapshot, at: written.addingTimeInterval(3 * 3600 + 51 * 60)), "4 h 1 min old")
    }

    /// The wall clock went back five hours: the measurement time looks a
    /// minute old, but the numbers are five hours old.
    func testAJumpBackDoesNotFreshenStaleNumbers() {
        let snapshot = codexSnapshot(fetchedAt: written.addingTimeInterval(-60), age: 5 * 3600)
        XCTAssertTrue(dimmed(snapshot, at: written))
        XCTAssertTrue(dimmed(snapshot, at: written.addingTimeInterval(-3600)), "an entry dated before the write is never younger")
    }

    /// Without a kept age (cswap's accounts), the measurement time decides.
    func testWithoutAnAgeTheMeasurementTimeDecides() {
        let snapshot = codexSnapshot(fetchedAt: written.addingTimeInterval(-60), age: nil)
        XCTAssertFalse(dimmed(snapshot, at: written))
        XCTAssertTrue(dimmed(snapshot, at: written.addingTimeInterval(4 * 3600)))
    }

    /// The timeline plans its dimming entry where the kept age crosses the
    /// line, not where the measurement time does.
    func testTheTimelineDimsWhenTheKeptAgeCrossesTheLine() {
        let snapshot = codexSnapshot(fetchedAt: written.addingTimeInterval(-5 * 3600 - 600), age: 600)
        let plan = TimelinePlan.plan(for: snapshot, now: written)
        XCTAssertTrue(plan.entries.contains(TimelinePlan.bucketEnd(written.addingTimeInterval(4 * 3600 - 600 + 1))),
                      "\(plan.entries)")
    }

    /// The age is part of the snapshot: written as a number or null, read
    /// back, and dropped when it is not a finite, non-negative number.
    func testTheAgeIsStoredAndChecked() throws {
        let snapshot = codexSnapshot(fetchedAt: written, age: 600)
        XCTAssertEqual(try SnapshotStore.decode(SnapshotStore.encode(snapshot)), snapshot)
        for bad in [-1.0, .infinity, .nan] {
            let sanitized = SnapshotValidator.sanitized(codexSnapshot(fetchedAt: written, age: bad))
            XCTAssertNil(sanitized.providers[0].accounts[0].ageSeconds, "\(bad)")
        }
    }
}
