import XCTest
@testable import UsageCore

final class ReloadSchedulerTests: XCTestCase {
    let t0 = utc(2026, 9, 27, 12, 0, 0)
    /// An arbitrary continuous reading for t0 on boot "a", far enough into
    /// the boot that readings days earlier are still positive.
    let c0: UInt64 = 20_000_000_000_000_000

    func fingerprint(_ change: (inout SnapshotSketch) -> Void = { _ in }) -> DisplayFingerprint {
        var sketch = SnapshotSketch()
        change(&sketch)
        return DisplayFingerprint(sketch.build())
    }

    /// Minutes after t0 on boot "a", with wall and continuous time agreeing.
    func at(_ m: Double) -> SchedulerClock {
        SchedulerClock(wall: t0.addingTimeInterval(m * 60),
                       continuous: UInt64(Int64(c0) + Int64(m * 60 * 1e9)), boot: "a")
    }

    /// State right after a request for the base fingerprint.
    func requested(at clock: SchedulerClock) -> ReloadState {
        ReloadState(lastRequest: clock, requested: fingerprint(), requests: [clock])
    }

    func decide(_ state: ReloadState, _ current: DisplayFingerprint, _ clock: SchedulerClock, conservative: Bool = false)
        -> (decision: ReloadDecision, state: ReloadState)
    {
        ReloadScheduler.decide(state, current: current, clock: clock, conservative: conservative)
    }

    // MARK: the clock

    func testSameBootAgesByTheContinuousClock() {
        let later = SchedulerClock(wall: t0.addingTimeInterval(-86_400), continuous: c0 + 600_000_000_000, boot: "a")
        XCTAssertEqual(later.seconds(since: at(0)), 600, "the wall clock moved back a day; ten minutes passed")
    }

    func testAnotherBootAgesByWallTimeClampedAtZero() {
        let after = SchedulerClock(wall: t0.addingTimeInterval(300), continuous: 1, boot: "b")
        XCTAssertEqual(after.seconds(since: at(0)), 300)
        let behind = SchedulerClock(wall: t0.addingTimeInterval(-300), continuous: 1, boot: "b")
        XCTAssertEqual(behind.seconds(since: at(0)), 0)
    }

    func testWithoutABootIdOnlyWallTimeCounts() {
        // Continuous readings say ten minutes, the wall says five: with no
        // boot id on either side the continuous clock is never trusted.
        let earlier = SchedulerClock(wall: t0, continuous: c0, boot: nil)
        let later = SchedulerClock(wall: t0.addingTimeInterval(300), continuous: c0 + 600_000_000_000, boot: nil)
        XCTAssertEqual(later.seconds(since: earlier), 300)
        let oneSided = SchedulerClock(wall: t0.addingTimeInterval(300), continuous: c0 + 600_000_000_000, boot: "a")
        XCTAssertEqual(oneSided.seconds(since: earlier), 300)
        let behind = SchedulerClock(wall: t0.addingTimeInterval(-300), continuous: c0 + 600_000_000_000, boot: nil)
        XCTAssertEqual(behind.seconds(since: earlier), 0, "clamped")
    }

    func testTheBootIdIsTheBootSessionUUIDOnly() throws {
        var size = 0
        XCTAssertEqual(sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0), 0)
        var buffer = [CChar](repeating: 0, count: size)
        XCTAssertEqual(sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0), 0)
        let uuid = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        XCTAssertEqual(SchedulerClock.now().boot, uuid)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(SchedulerClock.now().boot)))
    }

    func testTheRealClockReadsThisBoot() {
        let a = SchedulerClock.now()
        let b = SchedulerClock.now()
        XCTAssertNotNil(a.boot)
        XCTAssertEqual(a.boot, b.boot)
        XCTAssertGreaterThanOrEqual(b.continuous, a.continuous)
        XCTAssertGreaterThan(a.continuous, 0)
    }

    // MARK: spacing and classes

    func testFreshStateFiresAtOnce() {
        let (decision, state) = decide(ReloadState(), fingerprint(), at(0))
        XCTAssertTrue(decision.fire)
        XCTAssertEqual(decision.reasons, [.first])
        XCTAssertEqual(state.lastRequest, at(0))
        XCTAssertEqual(state.requested, fingerprint())
        XCTAssertEqual(state.requests, [at(0)])
    }

    func testNothingChangedNeverFires() {
        let (decision, state) = decide(requested(at: at(0)), fingerprint(), at(600))
        XCTAssertFalse(decision.fire)
        XCTAssertNil(decision.hold)
        XCTAssertFalse(state.pending)
    }

    func testOrdinaryChangeWaitsTenMinutes() {
        XCTAssertEqual(ReloadScheduler.spacing, 10 * 60)
        let changed = fingerprint { $0.five = 30 }
        var state = requested(at: at(0))
        for m in [1.0, 5, 9.9] {
            let result = decide(state, changed, at(m))
            XCTAssertFalse(result.decision.fire, "minute \(m)")
            XCTAssertEqual(result.decision.hold, .spacing)
            XCTAssertEqual(result.state.pendingSince, at(1).wall)
            state = result.state
        }
        let result = decide(state, changed, at(10))
        XCTAssertTrue(result.decision.fire)
        XCTAssertEqual(result.decision.reasons, [.percent])
        XCTAssertFalse(result.state.pending)
    }

    func testUrgentChangeWaitsTenMinutes() {
        let changed = fingerprint { $0.active = "2" }
        let held = decide(requested(at: at(0)), changed, at(2))
        XCTAssertFalse(held.decision.fire)
        XCTAssertTrue(held.decision.urgent)
        XCTAssertFalse(decide(held.state, changed, at(9.9)).decision.fire)
        XCTAssertTrue(decide(held.state, changed, at(10)).decision.fire)
    }

    func testEveryUrgentClassUsesTheTenMinuteSpacing() {
        let soon = t0.addingTimeInterval(3600)
        let changes: [(String, (inout SnapshotSketch) -> Void)] = [
            ("status", { $0.accountStatus = .reloginRequired }),
            ("provider status", { $0.providerStatus = .error }),
            ("active", { $0.active = "2" }),
            ("layout", { $0.secondAccount = false }),
            ("band", { $0.seven = 90 }),
            ("reset", { $0.fiveReset = soon }),
        ]
        for (name, change) in changes {
            XCTAssertFalse(decide(requested(at: at(0)), fingerprint(change), at(9)).decision.fire, name)
            XCTAssertTrue(decide(requested(at: at(0)), fingerprint(change), at(10)).decision.fire, name)
        }
    }

    func testEveryOrdinaryClassUsesTheOrdinarySpacing() {
        let far = t0.addingTimeInterval(3 * 86_400)
        let base = ReloadState(lastRequest: at(0), requested: fingerprint { $0.sevenReset = far }, requests: [at(0)])
        let changes: [(String, (inout SnapshotSketch) -> Void)] = [
            ("percent", { $0.sevenReset = far; $0.five = 40 }),
            ("pace", { $0.sevenReset = far; $0.sevenExpected = 50 }),
            ("reset moved far out", { $0.sevenReset = far.addingTimeInterval(900) }),
        ]
        for (name, change) in changes {
            XCTAssertFalse(decide(base, fingerprint(change), at(9.9)).decision.fire, name)
            XCTAssertTrue(decide(base, fingerprint(change), at(10)).decision.fire, name)
        }
    }

    func testAHeldChangeIsNeverForgotten() {
        let changed = fingerprint { $0.seven = 95 }
        var state = requested(at: at(0))
        var fired: [Double] = []
        for m in stride(from: 2.0, through: 12, by: 1) {
            let result = decide(state, changed, at(m))
            if result.decision.fire { fired.append(m) }
            state = result.state
        }
        XCTAssertEqual(fired, [10])
    }

    func testAChangeThatRevertsBeforeFiringIsDropped() {
        let held = decide(requested(at: at(0)), fingerprint { $0.five = 60 }, at(2))
        let reverted = decide(held.state, fingerprint(), at(70))
        XCTAssertFalse(reverted.decision.fire)
        XCTAssertFalse(reverted.state.pending)
    }

    // MARK: clock changes

    func testAWallClockJumpBackKeepsHistoryAndMeasuresRealTime() {
        let state = ReloadState(lastRequest: at(0), requested: fingerprint(), requests: [at(-30), at(0)])
        let jumpedBack = SchedulerClock(wall: t0.addingTimeInterval(-86_400), continuous: c0 + 11 * 60_000_000_000,
                                        boot: "a")
        let result = decide(state, fingerprint { $0.active = "2" }, jumpedBack)
        XCTAssertTrue(result.decision.fire, "eleven real minutes have passed")
        XCTAssertEqual(result.state.requests.count, 3, "no request is forgotten because of the wall clock")
    }

    func testAWallClockJumpForwardDoesNotFakeElapsedTime() {
        let jumpedAhead = SchedulerClock(wall: t0.addingTimeInterval(2 * 3600), continuous: c0 + 5 * 60_000_000_000,
                                         boot: "a")
        let result = decide(requested(at: at(0)), fingerprint { $0.active = "2" }, jumpedAhead)
        XCTAssertFalse(result.decision.fire, "only five real minutes have passed")
        XCTAssertEqual(result.decision.hold, .spacing)
    }

    func testAfterARebootWallTimeCountsAndFutureEntriesAreKept() {
        let rebootedBehind = SchedulerClock(wall: t0.addingTimeInterval(-3600), continuous: 1, boot: "b")
        let held = decide(requested(at: at(0)), fingerprint { $0.active = "2" }, rebootedBehind)
        XCTAssertFalse(held.decision.fire, "a request from the future counts as just made")
        XCTAssertEqual(held.state.requests.count, 1, "and it is not discarded")
        let rebootedLater = SchedulerClock(wall: t0.addingTimeInterval(11 * 60), continuous: 2, boot: "b")
        XCTAssertTrue(decide(requested(at: at(0)), fingerprint { $0.active = "2" }, rebootedLater).decision.fire)
    }

    // MARK: the cap

    func testDailyCapIs40AndHoldsEvenUrgentChanges() {
        XCTAssertEqual(ReloadScheduler.dailyCap, 40)
        let requests = (0..<40).map { at(-60 - Double($0) * 30) }
        let state = ReloadState(lastRequest: requests[0], requested: fingerprint(), requests: requests)
        let urgent = fingerprint { $0.active = "2" }
        let held = decide(state, urgent, at(0))
        XCTAssertFalse(held.decision.fire)
        XCTAssertEqual(held.decision.hold, .cap)
        let oldest = -60 - 39 * 30.0
        XCTAssertFalse(decide(held.state, urgent, at(oldest + 1440 - 0.1)).decision.fire)
        let fired = decide(held.state, urgent, at(oldest + 1440 + 0.1))
        XCTAssertTrue(fired.decision.fire)
        XCTAssertEqual(fired.state.requests.count, 40)
    }

    func testFutureDatedEntriesCountTowardsTheCap() {
        let future = (0..<40).map { SchedulerClock(wall: t0.addingTimeInterval(3600 + Double($0)), continuous: UInt64($0), boot: "old") }
        let state = ReloadState(lastRequest: nil, requested: fingerprint(), requests: future)
        let result = decide(state, fingerprint { $0.active = "2" }, at(0))
        XCTAssertFalse(result.decision.fire)
        XCTAssertEqual(result.decision.hold, .cap)
    }

    func testRequestsOlderThanADayArePruned() {
        let old = (0..<45).map { at(-1500 - Double($0)) }
        let state = ReloadState(lastRequest: old[0], requested: fingerprint(), requests: old)
        let result = decide(state, fingerprint { $0.active = "2" }, at(0))
        XCTAssertTrue(result.decision.fire)
        XCTAssertEqual(result.state.requests, [at(0)])
    }

    /// The agent asks for at most 40 reloads a day, the low end of
    /// WidgetKit's 40 to 70; the widget's own timeline asks at most once
    /// every 3 hours, 8 a day. The worst day is 48.
    func testTheCombinedBudgetIsFortyEight() {
        let widgetOwn = Int((24 * 3600) / TimelinePlan.reloadFloor)
        XCTAssertEqual(widgetOwn, 8)
        XCTAssertEqual(ReloadScheduler.dailyCap + widgetOwn, 48)
    }

    func testEachRequestIsNumbered() {
        let first = decide(ReloadState(), fingerprint(), at(0))
        XCTAssertEqual(first.decision.id, 1)
        XCTAssertEqual(first.state.lastRequestId, 1)
        let second = decide(first.state, fingerprint { $0.active = "2" }, at(11))
        XCTAssertEqual(second.decision.id, 2)
        let held = decide(second.state, fingerprint { $0.active = "3" }, at(12))
        XCTAssertNil(held.decision.id)
        XCTAssertEqual(held.state.lastRequestId, 2)
    }

    func testTheNextOrdinaryTime() {
        var state = requested(at: at(0))
        XCTAssertEqual(ReloadScheduler.nextOrdinary(state, clock: at(5), conservative: false), at(10).wall)
        XCTAssertEqual(ReloadScheduler.nextOrdinary(state, clock: at(5), conservative: true), at(60).wall)
        XCTAssertEqual(ReloadScheduler.nextOrdinary(state, clock: at(30), conservative: false), at(30).wall, "already")
        let full = (0..<40).map { at(-Double($0) * 30) }
        state = ReloadState(lastRequest: full[0], requested: fingerprint(), requests: full)
        XCTAssertEqual(ReloadScheduler.nextOrdinary(state, clock: at(1), conservative: false), at(-39 * 30 + 1440).wall,
                       "at the cap: when the oldest request leaves the day")
    }

    /// A state holding more than 40 requests (from an earlier build with a
    /// higher cap): the next request can go once enough have left the day,
    /// with 60 in it, when the 21st oldest expires.
    func testTheNextOrdinaryTimeOverTheCap() {
        let requests = (0..<60).map { at(-Double($0) * 20) }
        let state = ReloadState(lastRequest: requests[0], requested: fingerprint(), requests: requests)
        XCTAssertEqual(ReloadScheduler.nextOrdinary(state, clock: at(1), conservative: false),
                       at(-Double(59 - 20) * 20 + 1440).wall)
    }

    /// A file from the build with the adaptive cap still reads; its budget
    /// fields are ignored.
    func testAStateFileWithTheOldBudgetFieldsStillReads() throws {
        let url = try temporaryDirectory().appendingPathComponent(ReloadStateStore.fileName)
        let json = #"{"version": 2, "pending": false, "requests": [], "budgetCap": 36, "lastRequestId": 8,"#
            + #" "budgetMeasure": {"honoured": 23, "requested": 23}}"#
        try Data(json.utf8).write(to: url)
        guard case .loaded(let state) = ReloadStateStore.read(from: url) else { return XCTFail("not read") }
        XCTAssertEqual(state.lastRequestId, 8)
    }

    // MARK: conservative mode

    func testConservativeModeAllowsOneRequestAnHour() {
        let urgent = fingerprint { $0.active = "2" }
        XCTAssertFalse(decide(requested(at: at(0)), urgent, at(11), conservative: true).decision.fire)
        XCTAssertFalse(decide(requested(at: at(0)), urgent, at(59), conservative: true).decision.fire)
        XCTAssertTrue(decide(requested(at: at(0)), urgent, at(60), conservative: true).decision.fire)
        XCTAssertTrue(decide(ReloadState(), urgent, at(0), conservative: true).decision.fire, "a first request")
    }

    // MARK: persistence

    func testStatePersistsAndReportsWhatItFound() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent(ReloadStateStore.fileName)
        XCTAssertEqual(ReloadStateStore.read(from: url), .missing)
        let held = decide(requested(at: at(0)), fingerprint { $0.five = 60 }, at(2)).state
        try ReloadStateStore.write(held, to: url)
        XCTAssertEqual(ReloadStateStore.read(from: url), .loaded(held))

        try Data("{".utf8).write(to: url)
        guard case .unreadable = ReloadStateStore.read(from: url) else { return XCTFail("garbage is unreadable") }
    }

    /// A version 1 file is migrated, not dropped: its requests keep counting
    /// against the daily cap, aged by wall time since they carry no boot id.
    func testAStateFileFromTheOlderBuildKeepsItsBudget() throws {
        let url = try temporaryDirectory().appendingPathComponent(ReloadStateStore.fileName)
        let requests = (0..<40).map { t0.timeIntervalSince1970 - 3600 - Double($0) * 1800 }
        let v1: [String: Any] = ["lastRequestAt": requests[0], "pending": false, "requests": requests]
        try JSONSerialization.data(withJSONObject: v1).write(to: url)
        guard case .loaded(let migrated) = ReloadStateStore.read(from: url) else {
            return XCTFail("a version 1 file must be migrated")
        }
        XCTAssertEqual(migrated.requests.count, 40)
        XCTAssertNil(try XCTUnwrap(migrated.requests.first).boot)
        XCTAssertEqual(migrated.lastRequest?.wall, Date(timeIntervalSince1970: requests[0]))
        let result = decide(migrated, fingerprint { $0.active = "2" }, at(0))
        XCTAssertFalse(result.decision.fire, "40 recent version 1 requests still block a 41st")
        XCTAssertEqual(result.decision.hold, .cap)
    }

    /// The fixture holds the bytes 101fc3d's own encoder wrote (generated
    /// from a checkout of that commit). Its fingerprints have no measurement
    /// times, which would block every aging reload, so the migration keeps
    /// the request history (the budget) and drops the fingerprint.
    func testAVersionOneFileKeepsItsBudgetButNotItsFingerprint() throws {
        let url = try temporaryDirectory().appendingPathComponent(ReloadStateStore.fileName)
        try fixture("reload-state-v1-101fc3d").write(to: url)
        guard case .loaded(let migrated) = ReloadStateStore.read(from: url) else {
            return XCTFail("the version 1 file must be migrated")
        }
        XCTAssertNil(migrated.requested, "an unknown fingerprint: the next poll counts as a change")
        XCTAssertFalse(migrated.pending)
        XCTAssertNil(migrated.pendingSince)
        XCTAssertEqual(migrated.requests.count, 28)
        XCTAssertTrue(migrated.requests.allSatisfy { $0.boot == nil })
        XCTAssertEqual(migrated.lastRequest?.wall, ISODate.parse("2026-01-15T11:50:00Z"))

        // Minutes after 12:00 on the fixture's day.
        func noon(_ m: Double) -> SchedulerClock {
            SchedulerClock(wall: utc(2026, 1, 15, 12, 0, 0).addingTimeInterval(m * 60),
                           continuous: UInt64(Int64(c0) + Int64(m * 60 * 1e9)), boot: "a")
        }
        // At 12:00, ten minutes after the last, the change goes, and the 28
        // requests of the last 14 hours still count toward the day's 40.
        let now = decide(migrated, fingerprint(), noon(0))
        XCTAssertEqual(now.decision.reasons, [.first])
        XCTAssertTrue(now.decision.fire)
        XCTAssertEqual(now.state.requests.count, 29)
        // A day later they have aged out and the change goes through.
        let fired = decide(migrated, fingerprint(), noon(25 * 60))
        XCTAssertTrue(fired.decision.fire)
        XCTAssertEqual(fired.state.requested, fingerprint())
    }

    /// The fixture holds the bytes 9cf8fc0's own encoder wrote: version 2,
    /// but fingerprints without measurement times. The shown time is then
    /// unknown, so fresher numbers earn one ordinary aging reload, after
    /// the usual spacing, and nothing more.
    func testALegacyVersionTwoFingerprintGetsOneAgingReloadAfterSpacing() throws {
        let url = try temporaryDirectory().appendingPathComponent(ReloadStateStore.fileName)
        try fixture("reload-state-v2-9cf8fc0").write(to: url)
        guard case .loaded(let legacy) = ReloadStateStore.read(from: url) else { return XCTFail("must load as version 2") }
        XCTAssertNil(legacy.requested?.providers["claude"]?.accounts["1"]?.fetchedAt, "the legacy shape")

        let eleven = ISODate.parse("2026-01-15T11:00:00Z")!
        let accounts = try CswapListMapper.accounts(from: fixture("cswap-list-sample"))
        let current = DisplayFingerprint(UsageSnapshot(writtenAt: eleven, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: accounts),
        ]))
        func clock(_ m: Double) -> SchedulerClock {
            SchedulerClock(wall: eleven.addingTimeInterval(m * 60), continuous: c0 + UInt64(m * 60e9), boot: "a")
        }
        let first = decide(legacy, current, clock(0))
        XCTAssertEqual(first.decision.reasons, [.aging])
        XCTAssertTrue(first.decision.fire, "ten minutes after the last request, at 10:50")

        var state = first.state
        var fired: [Double] = []
        for m in stride(from: 1.0, through: 90, by: 1) {
            let result = decide(state, current, clock(m))
            if result.decision.fire { fired.append(m) }
            state = result.state
        }
        XCTAssertEqual(fired, [], "once only")
    }

    func testAnUnknownVersionIsUnreadable() throws {
        let url = try temporaryDirectory().appendingPathComponent(ReloadStateStore.fileName)
        try Data(#"{"version": 9, "requests": []}"#.utf8).write(to: url)
        guard case .unreadable = ReloadStateStore.read(from: url) else { return XCTFail("expected unreadable") }
    }

    func testADirectoryInPlaceOfTheFileIsUnreadable() throws {
        let url = try temporaryDirectory().appendingPathComponent(ReloadStateStore.fileName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard case .unreadable = ReloadStateStore.read(from: url) else { return XCTFail("expected unreadable") }
        XCTAssertThrowsError(try ReloadStateStore.write(ReloadState(), to: url))
    }
}
