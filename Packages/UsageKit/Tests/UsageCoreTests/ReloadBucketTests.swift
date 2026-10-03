import XCTest
@testable import UsageCore

/// Background reloads are paced by a token bucket: at most 6 saved up, one
/// more every 36 minutes (40 a day). A busy afternoon can no longer spend
/// the whole day's reloads and leave the night with none.
final class ReloadBucketTests: XCTestCase {
    let t0 = utc(2026, 10, 2, 12, 0, 0)
    let c0: UInt64 = 20_000_000_000_000_000

    func fingerprint(active: String) -> DisplayFingerprint {
        var sketch = SnapshotSketch()
        sketch.active = active
        return DisplayFingerprint(sketch.build())
    }

    /// Minutes after t0 on boot "a", wall and continuous time agreeing.
    func at(_ m: Double) -> SchedulerClock {
        SchedulerClock(wall: t0.addingTimeInterval(m * 60),
                       continuous: UInt64(Int64(c0) + Int64(m * 60 * 1e9)), boot: "a")
    }

    func testTheBucketHoldsSixAndRefillsOneEvery36Minutes() {
        XCTAssertEqual(ReloadBucket.capacity, 6)
        XCTAssertEqual(ReloadBucket.refill, 36 * 60)
        XCTAssertEqual(24 * 3600 / ReloadBucket.refill, 40, "40 a day, as before")
        var state = ReloadState()
        XCTAssertEqual(ReloadBucket.tokens(state, at: at(0)), 6, "a new or older state starts full")
        for _ in 0..<6 { XCTAssertTrue(ReloadBucket.spend(&state, at: at(0))) }
        XCTAssertFalse(ReloadBucket.spend(&state, at: at(0)), "empty")
        XCTAssertEqual(ReloadBucket.tokens(state, at: at(36)), 1, accuracy: 1e-9)
        XCTAssertEqual(ReloadBucket.tokens(state, at: at(36 * 10)), 6, accuracy: 1e-9, "never above six")
    }

    /// A change every 10 minutes for two days: reloads go through every
    /// hour of both days, never more than 40 in a day.
    func testABusyDayIsSpreadOverEveryHour() {
        var state = ReloadState()
        var fired: [Double] = []
        for minute in 0..<(48 * 60) {
            let current = fingerprint(active: (minute / 10) % 2 == 0 ? "1" : "2")
            let result = ReloadScheduler.decide(state, current: current, clock: at(Double(minute)))
            state = result.state
            if result.decision.fire { fired.append(Double(minute)) }
        }
        for hour in 0..<48 {
            XCTAssertTrue(fired.contains { $0 >= Double(hour * 60) && $0 < Double(hour * 60 + 60) }, "no reload in hour \(hour)")
        }
        for day in 0..<2 {
            let count = fired.filter { $0 >= Double(day * 1440) && $0 < Double(day * 1440 + 1440) }.count
            XCTAssertLessThanOrEqual(count, ReloadScheduler.dailyCap, "day \(day)")
            XCTAssertGreaterThanOrEqual(count, 24, "day \(day)")
        }
    }

    func testNoTokenHoldsAChangeUntilOneArrives() {
        var state = ReloadState(lastRequest: at(-60), requested: fingerprint(active: "1"))
        state.bucketTokens = 0
        state.bucketAt = at(0)
        let held = ReloadScheduler.decide(state, current: fingerprint(active: "2"), clock: at(20))
        XCTAssertFalse(held.decision.fire)
        XCTAssertEqual(held.decision.hold, .tokens)
        XCTAssertEqual(ReloadScheduler.nextOrdinary(state, clock: at(20), conservative: false), at(36).wall)
        let fired = ReloadScheduler.decide(held.state, current: fingerprint(active: "2"), clock: at(36))
        XCTAssertTrue(fired.decision.fire)
        XCTAssertEqual(ReloadBucket.tokens(fired.state, at: at(36)), 0, accuracy: 1e-9)
    }

    /// The bucket is saved with the rest of the state and read back.
    func testTheBucketSurvivesARestart() throws {
        var state = ReloadState()
        for _ in 0..<4 { _ = ReloadBucket.spend(&state, at: at(0)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bucket-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ReloadStateStore.write(state, to: url)
        guard case .loaded(let read) = ReloadStateStore.read(from: url) else { return XCTFail("not read back") }
        XCTAssertEqual(ReloadBucket.tokens(read, at: at(0)), 2, accuracy: 1e-9)
        XCTAssertEqual(ReloadBucket.tokens(read, at: at(36)), 3, accuracy: 1e-9)
    }

    /// Refill follows the continuous clock: setting the wall clock ahead
    /// does not hand out tokens, and setting it back does not take any.
    func testAWallClockChangeNeitherAddsNorTakesTokens() {
        var state = ReloadState()
        for _ in 0..<6 { _ = ReloadBucket.spend(&state, at: at(0)) }
        let ahead = SchedulerClock(wall: t0.addingTimeInterval(5 * 3600), continuous: at(1).continuous, boot: "a")
        XCTAssertEqual(ReloadBucket.tokens(state, at: ahead), 1.0 / 36, accuracy: 1e-9)
        let back = SchedulerClock(wall: t0.addingTimeInterval(-5 * 3600), continuous: at(72).continuous, boot: "a")
        XCTAssertEqual(ReloadBucket.tokens(state, at: back), 2, accuracy: 1e-9)
    }

    /// What the status window shows: whole tokens and the next one's time.
    func testTheStatusShowsTokensAndTheNextRefill() {
        var state = ReloadState()
        for _ in 0..<6 { _ = ReloadBucket.spend(&state, at: at(0)) }
        let status = ReloadBucket.status(state, at: at(40))
        XCTAssertEqual(status.available, 1)
        XCTAssertEqual(status.nextRefill, at(72).wall)
        let full = ReloadBucket.status(ReloadState(), at: at(0))
        XCTAssertEqual(full.available, 6)
        XCTAssertNil(full.nextRefill, "a full bucket has nothing to refill")
    }

    /// A press's completion may take the bucket one token into debt, so a
    /// press that worked always redraws; only one debt at a time, and the
    /// next refill repays it. Background reloads never borrow.
    func testAPressMayGoOneTokenIntoDebt() {
        var state = ReloadState()
        for _ in 0..<6 { ReloadBucket.spend(&state, at: at(0)) }
        XCTAssertFalse(ReloadBucket.spend(&state, at: at(0)), "a background reload never borrows")
        XCTAssertTrue(ReloadBucket.spend(&state, at: at(0), mayBorrow: true))
        XCTAssertEqual(ReloadBucket.tokens(state, at: at(0)), -1, accuracy: 1e-9)
        XCTAssertFalse(ReloadBucket.spend(&state, at: at(10), mayBorrow: true), "one debt at a time")
        XCTAssertEqual(ReloadBucket.status(state, at: at(10)).available, 0, "shown as none")
        XCTAssertEqual(ReloadBucket.status(state, at: at(10)).nextRefill, at(72).wall, "the first usable token")
        XCTAssertTrue(ReloadBucket.spend(&state, at: at(36), mayBorrow: true), "repaid by the next refill")
    }
}
