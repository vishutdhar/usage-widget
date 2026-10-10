import XCTest
import UsageCore
@testable import UsageAgentCore

/// The agent's side of the refresh button. A press polls at once with a
/// fresh measurement; once the snapshot answering it is written, the agent
/// asks for one reload, always: never refused for spacing, the daily cap
/// or the conservative hour. It is recorded as a request and takes no
/// token from the reload bucket. A press never runs the background
/// decision and never leaves a note about limits.

final class RefreshAgentTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func ok(_ pct: Double = 20, active: String = "1") -> Result<RunOutput, RunFailure> {
        .success(RunOutput(exitCode: 0, stdout: listJSON([("1", active == "1", pct), ("2", active == "2", 10)])))
    }

    func state(_ dir: URL) -> ReloadState? {
        if case .loaded(let s) = ReloadStateStore.read(from: dir.appendingPathComponent(ReloadStateStore.fileName)) { return s }
        return nil
    }

    func log(_ dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(SharedContainer.agentLogFileName), encoding: .utf8)
    }

    /// `count` background requests in the last day, the newest a minute ago.
    func seedRequests(_ dir: URL, count: Int) throws {
        let recent = (0..<count).map { i in
            SchedulerClock(wall: start.addingTimeInterval(Double(-60 - i * 60)), continuous: 0, boot: nil)
        }
        try ReloadStateStore.write(ReloadState(lastRequest: recent.first, requests: recent),
                                   to: dir.appendingPathComponent(ReloadStateStore.fileName))
    }

    func press(_ agent: UsageAgent, _ dir: URL, _ clock: ManualClock) async throws -> TickReport? {
        try RefreshRequestStore.request(in: dir, at: clock.now)
        guard await agent.takeRefreshRequest() else { return nil }
        return await agent.tick(userRequested: true)
    }

    /// A press is taken once: cswap runs at once, and once its answer is
    /// written one press reload goes, reason user, logged as a press; it is
    /// not among the background requests the cap counts.
    func testARequestPollsNowAndReloadsOnce() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let runner = ScriptedRunner([ok()])
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        XCTAssertEqual(reloads.count, 1, "the first request")
        clock.advance(20)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        let again = await agent.takeRefreshRequest()
        XCTAssertFalse(again, "the same request is taken once")
        let report = await agent.tick(userRequested: true)
        XCTAssertEqual(runner.calls, 2, "cswap ran again at once")
        XCTAssertEqual(report.reloadReasons, [.user])
        XCTAssertEqual(reloads.count, 2)
        let last = try XCTUnwrap(try log(dir).split(separator: "\n").last)
        XCTAssertTrue(last.contains("reasons=user") && last.contains("kind=press") && last.contains("id=2"), String(last))
        XCTAssertEqual(state(dir)?.requests.count, 1, "the first poll's; the press reload is not a background request")
        XCTAssertEqual(state(dir)?.lastCapExemption?.wall, clock.now, "kept as the last press reload")
        clock.advance(31)
        let later = await agent.takeRefreshRequest()
        XCTAssertFalse(later, "past the debounce, the same press is still not taken again")
    }

    /// Presses within 30 s of the last one handled are ignored.
    func testPressesWithinThirtySecondsAreIgnored() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(5)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let first = await agent.takeRefreshRequest()
        XCTAssertTrue(first)
        _ = await agent.tick(userRequested: true)
        clock.advance(29)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let second = await agent.takeRefreshRequest()
        XCTAssertFalse(second, "29 s after the last")
        clock.advance(2)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let third = await agent.takeRefreshRequest()
        XCTAssertTrue(third, "31 s after the last")
    }

    /// At the ceiling a press still polls, and its answer still gets its
    /// reload: a press is never refused for the daily cap, and it does not
    /// add to the background requests the cap counts. No note about limits
    /// is left.
    func testAPressAtTheCapStillReloads() async throws {
        let dir = try makeTemporaryDirectory()
        try seedRequests(dir, count: ReloadScheduler.dailyCap)
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                               clock: { clock.stamp })
        clock.advance(5)
        let request = try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        let report = await agent.tick(userRequested: true)
        XCTAssertEqual(reloads.count, 1, "the press's reload, at the cap")
        XCTAssertTrue(report.reloadReasons.contains(.user))
        XCTAssertTrue(RefreshState.answers(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")), request))
        XCTAssertEqual(state(dir)?.requests.count, ReloadScheduler.dailyCap, "the cap's count is unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("refresh-result.json").path))
    }

    /// A press's reload takes no token from the reload bucket and borrows
    /// none: with the bucket empty it still goes, and the bucket holds only
    /// what refilled meanwhile. A second press later reloads again.
    func testAPressWithAnEmptyBucketReloadsAndTakesNoToken() async throws {
        let dir = try makeTemporaryDirectory()
        var seeded = ReloadState()
        seeded.bucketTokens = 0
        seeded.bucketAt = SchedulerClock(wall: start, continuous: 0, boot: nil)
        try ReloadStateStore.write(seeded, to: dir.appendingPathComponent(ReloadStateStore.fileName))
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                               clock: { clock.stamp })
        clock.advance(5)
        let report = try await press(agent, dir, clock)
        XCTAssertEqual(reloads.count, 1, "an empty bucket does not hold a press")
        XCTAssertTrue(report?.reloadReasons.contains(.user) ?? false)
        XCTAssertEqual(ReloadBucket.tokens(try XCTUnwrap(state(dir)), at: clock.stamp), 5 / ReloadBucket.refill,
                       accuracy: 1e-6, "only the refill of the 5 s before the press: nothing taken, nothing owed")
        clock.advance(11 * 60)
        let second = try await press(agent, dir, clock)
        XCTAssertEqual(reloads.count, 2)
        XCTAssertTrue(second?.reloadReasons.contains(.user) ?? false)
    }

    /// A Codex app-server call can take up to its 20 s timeout: the
    /// snapshot is dated after it, with Codex's age measured then too.
    func testTheSnapshotIsDatedAfterTheCodexCall() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let measured = start.addingTimeInterval(-300)
        let codex = FakeCodex(rollout: CodexReading(source: .rollout, measuredAt: measured,
                                                    windows: [UsageWindow(kind: .weekly, name: "Weekly",
                                                                          windowSeconds: 604_800, usedPct: 10)]),
                              appServer: [.failure(FetchFailure(reason: "unused"))])
        codex.setAnswerNow {
            clock.advance(19)
            return .failure(FetchFailure(reason: "codex app-server did not answer within 20 s"))
        }
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        let report = await agent.tick()
        XCTAssertEqual(codex.appServerCalls, 1)
        XCTAssertEqual(report.writtenAt, start.addingTimeInterval(19))
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(snapshot.writtenAt, start.addingTimeInterval(19))
        let age = try XCTUnwrap(snapshot.provider(CodexMerge.provider)?.accounts.first?.ageSeconds)
        XCTAssertEqual(age, 319, accuracy: 0.001, "the rollout's age when the snapshot is dated, 19 s after the poll")
    }

    /// A wall clock set back during the Codex call does not make a rollout
    /// reading look fresh: its age is taken when it was read, and carried
    /// to the snapshot's time on the continuous clock.
    func testAClockSetBackDuringTheCodexCallKeepsTheRolloutsAge() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: CodexReading(source: .rollout, measuredAt: start.addingTimeInterval(-5 * 3600),
                                                    windows: [UsageWindow(kind: .weekly, name: "Weekly",
                                                                          windowSeconds: 604_800, usedPct: 10)]),
                              appServer: [.failure(FetchFailure(reason: "unused"))])
        codex.setAnswerNow {
            clock.advance(19)
            clock.setWall(clock.now.addingTimeInterval(-6 * 3600))
            return .failure(FetchFailure(reason: "codex app-server did not answer within 20 s"))
        }
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        let age = try XCTUnwrap(snapshot.provider(CodexMerge.provider)?.accounts.first?.ageSeconds)
        XCTAssertEqual(age, 5 * 3600 + 19, accuracy: 0.001)
    }

    /// The scheduler decides on the clock after the Codex step: a poll that
    /// starts 590 s after the last reload and ends 19 s later is past the
    /// 10 minute spacing, and its change goes.
    func testTheSchedulerDecidesAfterTheCodexStep() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let slow = SlowSteps()
        let codex = FakeCodex(rollout: nil, appServer: [.failure(FetchFailure(reason: "unused"))])
        codex.setRolloutAt { _ in
            if slow.on { clock.advance(19) }
            return nil
        }
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok(20), ok(55)]),
                               reload: { reloads.increment() }, clock: { clock.stamp }, codex: codex)
        _ = await agent.tick()
        XCTAssertEqual(reloads.count, 1)
        clock.advance(590)
        slow.on = true
        let report = await agent.tick()
        XCTAssertEqual(reloads.count, 2, "609 s after the last request when it decides; \(report.reloadReasons)")
    }

    /// The same with the time spent in an app-server call: a restarted agent
    /// asks Codex 590 s after the last reload, the call takes 19 s, and the
    /// scheduler, deciding after it, lets the change go.
    func testTheSchedulerDecidesAfterTheAppServerCall() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let weekly = { (date: Date) in
            CodexReading(source: .appServer, measuredAt: date,
                         windows: [UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 10)])
        }
        let first = FakeCodex(rollout: nil, appServer: [.success(weekly(start))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok(20)]), reload: { reloads.increment() },
                               clock: { clock.stamp }, codex: first)
        _ = await agent.tick()
        XCTAssertEqual(reloads.count, 1)
        clock.advance(590)
        let slow = FakeCodex(rollout: nil, appServer: [.success(weekly(start))])
        slow.setAnswerNow {
            clock.advance(19)
            return .success(weekly(clock.now))
        }
        let restarted = UsageAgent(directory: dir, runner: ScriptedRunner([ok(55)]), reload: { reloads.increment() },
                                   clock: { clock.stamp }, codex: slow)
        _ = await restarted.tick()
        XCTAssertEqual(slow.appServerCalls, 1)
        XCTAssertEqual(reloads.count, 2, "609 s after the last request when it decides")
        XCTAssertEqual(state(dir)?.lastRequest?.wall, start.addingTimeInterval(609))
    }

    /// A cached Codex reading aging through a slow, failed call: 3 h 59 min
    /// 50 s old when the poll starts, 19 s more when the snapshot is dated,
    /// so it is written past Codex's 4 hour line.
    func testACachedCodexReadingAgesThroughASlowCall() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.failure(FetchFailure(reason: "unused"))])
        let calls = Counter()
        codex.setAnswerNow {
            calls.increment()
            if calls.count == 1 {
                return .success(CodexReading(source: .appServer, measuredAt: clock.now,
                                             windows: [UsageWindow(kind: .weekly, name: "Weekly",
                                                                   windowSeconds: 604_800, usedPct: 10)]))
            }
            clock.advance(19)
            return .failure(FetchFailure(reason: "codex app-server did not answer within 20 s"))
        }
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        clock.advance(4 * 3600 - 10)
        _ = await agent.tick()
        XCTAssertEqual(calls.count, 2, "Codex idle three hours: asked again")
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        let account = try XCTUnwrap(snapshot.provider(CodexMerge.provider)?.accounts.first)
        XCTAssertEqual(try XCTUnwrap(account.ageSeconds), 4 * 3600 + 9, accuracy: 0.001)
        XCTAssertTrue(Staleness.isDimmed(account, writtenAt: snapshot.writtenAt, at: snapshot.writtenAt,
                                         provider: CodexMerge.provider), "past the 4 hour line as written")
        XCTAssertEqual(account.status, .stale)
        XCTAssertEqual(account.statusNote, "No new reading")
    }

    /// Codex's age and the snapshot's date come from one clock reading: a
    /// pause after it (the look for Codex on disk, say) moves neither.
    func testCodexAgeAndTheSnapshotDateAgree() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let measured = start.addingTimeInterval(-(4 * 3600 - 10))
        let codex = FakeCodex(rollout: CodexReading(source: .rollout, measuredAt: measured,
                                                    windows: [UsageWindow(kind: .weekly, name: "Weekly",
                                                                          windowSeconds: 604_800, usedPct: 10)]),
                              appServer: [.failure(FetchFailure(reason: "codex app-server did not answer"))])
        let slow = SlowSteps()
        // 7 s reading the rollout (before the shared reading), 19 s looking
        // for Codex on disk (after it).
        codex.setRolloutAt { _ in
            if slow.on { clock.advance(7) }
            return CodexReading(source: .rollout, measuredAt: measured,
                                windows: [UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 10)])
        }
        codex.onFound = { if slow.on { clock.advance(19) } }
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok(20), ok(55)]), reload: { reloads.increment() },
                               clock: { clock.stamp }, codex: codex)
        _ = await agent.tick()
        XCTAssertEqual(reloads.count, 1)
        let firstRequest = try XCTUnwrap(state(dir)?.lastRequest)
        clock.advance(590)
        slow.on = true
        _ = await agent.tick()
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        let age = try XCTUnwrap(snapshot.provider(CodexMerge.provider)?.accounts.first?.ageSeconds)
        XCTAssertEqual(age, snapshot.writtenAt.timeIntervalSince(measured), accuracy: 0.001,
                       "aged to the moment the snapshot is dated")
        XCTAssertEqual(snapshot.writtenAt, start.addingTimeInterval(597), "after the rollout read, before the look on disk")
        XCTAssertEqual(reloads.count, 1, "the scheduler decides at the same reading: 597 s, inside the spacing")
        XCTAssertEqual(state(dir)?.lastRequest, firstRequest)
    }

    /// However long the answer takes (a 15 s cswap run and a 19 s Codex read
    /// write it 34 s after the press; cswap's own limit is 50 s), it gets
    /// the same one reload as a quick one, once it is on disk.
    func testASlowAnswerStillGetsExactlyOneReload() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let slow = SlowSteps()
        let codex = FakeCodex(rollout: nil, appServer: [.failure(FetchFailure(reason: "not asked"))])
        codex.setRolloutAt { date in
            if slow.on { clock.advance(19) }
            return CodexReading(source: .rollout, measuredAt: date,
                                windows: [UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 10)])
        }
        let agent = UsageAgent(directory: dir, runner: SlowRunner(clock: clock, slow: slow, seconds: 15),
                               reload: { reloads.increment() }, clock: { clock.stamp }, codex: codex)
        _ = await agent.tick()
        clock.advance(11 * 60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        let before = reloads.count
        slow.on = true
        let report = await agent.tick(userRequested: true)
        XCTAssertEqual(reloads.count - before, 1, "one reload, 34 s after the press, once the answer is on disk")
        XCTAssertTrue(report.reloadReasons.contains(.user))
    }

    /// A hundred presses, 31 s apart: each gets its one reload, none adds to
    /// the background requests, and nothing in the container speaks of a
    /// limit.
    func testAHundredPressesReloadOnceEach() async throws {
        let dir = try makeTemporaryDirectory()
        try seedRequests(dir, count: 20)
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                               clock: { clock.stamp })
        _ = await agent.tick()
        let before = try XCTUnwrap(state(dir))
        XCTAssertEqual(reloads.count, 0, "the first poll's own change is held by the spacing")
        var taken = 0
        for _ in 0..<100 {
            clock.advance(31)
            if try await press(agent, dir, clock) != nil { taken += 1 }
        }
        XCTAssertEqual(taken, 100)
        XCTAssertEqual(reloads.count, 100, "one reload per press")
        XCTAssertEqual(try XCTUnwrap(state(dir)).requests.count, before.requests.count, "the cap's count is unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("refresh-result.json").path))
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let text = String(decoding: try Data(contentsOf: dir.appendingPathComponent(name)), as: UTF8.self)
            XCTAssertFalse(text.lowercased().contains("limit reached"), name)
            XCTAssertFalse(text.contains("capped"), name)
        }
    }

    /// A press never runs the background decision: its one reload is the
    /// press's, showing whatever changed (the active account, here), and
    /// no token is spent though the background spacing has passed. The
    /// change it showed needs no second reload.
    func testAPressNeverRunsTheBackgroundDecision() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok(), ok(), ok(active: "2")]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(20 * 60)
        _ = try await press(agent, dir, clock)
        XCTAssertEqual(reloads.count, 2, "the first request, then the press's reload")
        clock.advance(11 * 60)
        let tokens = ReloadBucket.tokens(try XCTUnwrap(state(dir)), at: clock.stamp)
        let report = try await press(agent, dir, clock)
        let reasons = try XCTUnwrap(report?.reloadReasons)
        XCTAssertTrue(reasons.contains(.active) && reasons.contains(.user), "\(reasons)")
        XCTAssertEqual(reloads.count, 3, "the press's one reload")
        XCTAssertEqual(ReloadBucket.tokens(try XCTUnwrap(state(dir)), at: clock.stamp), tokens, accuracy: 1e-9,
                       "no background decision, so no token")
        clock.advance(11 * 60)
        let after = await agent.tick()
        XCTAssertEqual(after.reloadReasons, [], "the press already showed it")
        XCTAssertEqual(reloads.count, 3)
    }

    /// A press that arrives while the minute's poll is due is answered by
    /// that poll, which runs fresh for it and asks for the press's one
    /// reload: the loop does not run cswap again.
    func testAPressDuringADuePollIsAnsweredByThatPoll() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let runner = ScriptedRunner([ok()])
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let before = runner.calls
        _ = await agent.tick()
        let taken = await agent.takeRefreshRequest()
        XCTAssertFalse(taken, "answered by the poll that just wrote")
        XCTAssertEqual(runner.calls - before, 1, "one cswap run for the press")
        XCTAssertEqual(runner.freshFlags.last, true, "and it measured every account now")
        XCTAssertEqual(reloads.count, 2, "the first poll's, then the press's one reload")
        clock.advance(40)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let next = await agent.takeRefreshRequest()
        XCTAssertTrue(next, "a later press is taken as usual")
    }

    /// Every answered press gets one reload, quick or slow, taking no token
    /// and adding nothing to the cap's count: the intent no longer waits,
    /// so nothing else would show the numbers.
    func testEveryPressGetsOneReloadQuickOrSlow() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok(20), ok(30), ok(40)]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(11 * 60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        var taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        clock.advance(2)
        let quick = await agent.tick(userRequested: true)
        XCTAssertTrue(quick.reloadReasons.contains(.user), "answered in 2 s")
        XCTAssertEqual(reloads.count, 2)
        XCTAssertEqual(state(dir)?.requests.count, 1, "the first poll's only")
        let tokensBefore = ReloadBucket.tokens(try XCTUnwrap(state(dir)), at: clock.stamp)

        clock.advance(40)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        clock.advance(30)
        let slow = await agent.tick(userRequested: true)
        XCTAssertTrue(slow.reloadReasons.contains(.user), "answered in 30 s")
        XCTAssertEqual(reloads.count, 3)
        XCTAssertEqual(state(dir)?.requests.count, 1, "nothing added to the cap's count")
        XCTAssertEqual(ReloadBucket.tokens(try XCTUnwrap(state(dir)), at: clock.stamp),
                       tokensBefore + 70 / ReloadBucket.refill, accuracy: 1e-6, "and no token taken")
    }

    /// A press poll with no press on record still reloads once, to be sure
    /// the numbers show.
    func testAPressPollWithoutARecordedPressReloads() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok(20), ok(30)]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(11 * 60)
        _ = await agent.tick(userRequested: true)
        XCTAssertEqual(reloads.count, 2)
    }

    /// A press reload records what it showed: the next poll with the same
    /// numbers asks for nothing more.
    func testAPressReloadRecordsWhatItShowed() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok(20), ok(30)]), reload: { reloads.increment() },
                               clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(11 * 60)
        _ = try await press(agent, dir, clock)
        XCTAssertEqual(reloads.count, 2, "the press's reload showed 30%")
        clock.advance(11 * 60)
        _ = await agent.tick()
        XCTAssertEqual(reloads.count, 2, "30% was already asked for")
    }

    /// A scheduled poll that answers a press is the press's answer and asks
    /// for its one reload, however long ago the press was made.
    func testAScheduledPollAnsweringAPressAddsOnePressReload() async throws {
        for delay in [30.0, 1.0] {
            let dir = try makeTemporaryDirectory()
            let clock = ManualClock(start)
            let reloads = Counter()
            let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                                   clock: { clock.stamp })
            _ = await agent.tick()
            clock.advance(11 * 60)
            try RefreshRequestStore.request(in: dir, at: clock.now.addingTimeInterval(-delay))
            let report = await agent.tick()
            XCTAssertEqual(reloads.count - 1, 1, "pressed \(delay) s before the poll")
            XCTAssertTrue(report.reloadReasons.contains(.user))
            XCTAssertEqual(state(dir)?.requests.count, 1, "the first poll's only")
            let taken = await agent.takeRefreshRequest()
            XCTAssertFalse(taken, "the press was answered by that poll")
        }
    }

    /// A scheduled poll that answers a press, with a change it would
    /// otherwise reload for, is the press's answer: no background decision,
    /// and its one reload is the press's, not a background reload with a
    /// press reload on top.
    func testAPressAnsweredByAScheduledPollGetsOneReload() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let runner = ScriptedRunner([ok(20), ok(30)])
        let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(11 * 60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let report = await agent.tick()
        XCTAssertEqual(runner.freshFlags, [false, true], "measured fresh for the press")
        XCTAssertEqual(reloads.count, 2, "one reload for the poll, and no second one")
        XCTAssertTrue(report.reloadReasons.contains(.user), "the press's reload")
        XCTAssertTrue(try XCTUnwrap(try log(dir).split(separator: "\n").last).contains("kind=press"))
        XCTAssertEqual(state(dir)?.requests.count, 1, "no background request")
    }

    /// Two presses 0.3 s apart (the owner's Oct 1 case): the second falls
    /// inside the 30 s debounce. It is not ignored silently: the agent
    /// answers it at once with the last snapshot under the next number,
    /// runs no cswap, logs one fixed line, and asks for its reload.
    func testAPressInsideTheDebounceIsAnsweredFromTheLastSnapshot() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let runner = ScriptedRunner([ok()])
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        var taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        _ = await agent.tick(userRequested: true)
        let calls = runner.calls
        let before = reloads.count
        clock.advance(0.3)
        let second = try RefreshRequestStore.request(in: dir, at: clock.now)
        taken = await agent.takeRefreshRequest()
        XCTAssertFalse(taken, "inside the debounce: no second cswap run")
        XCTAssertEqual(runner.calls, calls)
        XCTAssertTrue(RefreshState.answers(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")), second),
                      "answered at once")
        XCTAssertEqual(reloads.count - before, 1, "with its reload")
        let log = try log(dir)
        XCTAssertEqual(log.components(separatedBy: "refresh press within 30 s of the last; answered with the last snapshot").count - 1, 1)
    }

    /// A press inside the debounce after the container was replaced: the
    /// answer goes through the same container check as a poll, so nothing
    /// is written into either folder and the agent stops.
    func testADebouncedAnswerAfterAReplacementWritesNothing() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        var taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        _ = await agent.tick(userRequested: true)
        // The second press reaches the old folder (this process's anchor), then
        // another folder is put at the path.
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let old = URL(fileURLWithPath: dir.path + ".old-\(UUID().uuidString)")
        XCTAssertEqual(rename(dir.path, old.path), 0)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let before = try String(contentsOf: old.appendingPathComponent("snapshot.json"), encoding: .utf8)
        let logBefore = try String(contentsOf: old.appendingPathComponent(SharedContainer.agentLogFileName), encoding: .utf8)
        clock.advance(1)
        taken = await agent.takeRefreshRequest()
        XCTAssertFalse(taken)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("snapshot.json"), encoding: .utf8), before)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent(SharedContainer.agentLogFileName), encoding: .utf8),
                       logBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
        let report = await agent.tick()
        XCTAssertTrue(report.containerChanged, "stopped")
    }

    /// A press whose answer cannot be written stays pending, with no reload:
    /// the error reaches the report, the next look tries again, and once
    /// writing works the press is answered and its reload goes.
    func testAPressWhoseAnswerCannotBeWrittenStaysPending() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                               clock: { clock.stamp })
        _ = await agent.tick()
        let first = reloads.count
        let snapshot = dir.appendingPathComponent("snapshot.json")
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
        clock.advance(60)
        let request = try RefreshRequestStore.request(in: dir, at: clock.now)
        var taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        let failed = await agent.tick(userRequested: true)
        XCTAssertNotNil(failed.writeError, "the status window shows why")
        clock.advance(2)
        taken = await agent.takeRefreshRequest()
        XCTAssertFalse(taken, "inside the debounce: a cheap try, not another cswap run")
        XCTAssertEqual(reloads.count, first, "no reload while nothing answers the press")
        try FileManager.default.removeItem(at: snapshot)
        clock.advance(2)
        taken = await agent.takeRefreshRequest()
        XCTAssertFalse(taken)
        XCTAssertTrue(RefreshState.answers(SnapshotStore.read(from: snapshot), request), "answered once a write worked")
        XCTAssertEqual(reloads.count, first + 1, "and its one reload with it")
    }

    /// A press inside the debounce gets its reload with the last snapshot's
    /// answer, whenever it is noticed.
    func testADebouncedAnswerAlwaysBringsOneReload() async throws {
        for noticed in [1.0, 26.0] {
            let dir = try makeTemporaryDirectory()
            let clock = ManualClock(start)
            let reloads = Counter()
            let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                                   clock: { clock.stamp })
            _ = await agent.tick()
            clock.advance(11 * 60)
            try RefreshRequestStore.request(in: dir, at: clock.now)
            var taken = await agent.takeRefreshRequest()
            XCTAssertTrue(taken)
            _ = await agent.tick(userRequested: true)
            let before = reloads.count
            try RefreshRequestStore.request(in: dir, at: clock.now)
            clock.advance(noticed)
            taken = await agent.takeRefreshRequest()
            XCTAssertFalse(taken)
            XCTAssertEqual(reloads.count - before, 1, "noticed \(noticed) s after the press")
            let last = try XCTUnwrap(try log(dir).split(separator: "\n").last)
            XCTAssertTrue(last.contains("kind=press"), String(last))
        }
    }

    /// Saves failed long enough for the status window to show it; storage
    /// recovers and the first save to work is a debounced press's. That
    /// save clears the error, as any successful save does. Both presses
    /// reloaded, the first though its time could not be saved.
    func testASuccessfulSaveOnTheDebouncedPathClearsTheStateError() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let saver = FlakySaver()
        saver.failing = true
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                               clock: { clock.stamp }, saveState: saver.save)
        let failing = await agent.tick()
        XCTAssertNotNil(failing.stateError)
        clock.advance(61 * 60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        let quick = await agent.tick(userRequested: true)
        XCTAssertNotNil(quick.stateError, "still failing")
        XCTAssertEqual(reloads.count, 1, "the press reloads though its time could not be saved")
        saver.failing = false
        try RefreshRequestStore.request(in: dir, at: clock.now)
        clock.advance(26)
        let second = await agent.takeRefreshRequest()
        XCTAssertFalse(second)
        XCTAssertEqual(reloads.count, 2, "the debounced answer's reload")
        clock.advance(1)
        let report = await agent.tick()
        XCTAssertNil(report.stateError, "the save that worked cleared it")
    }

    /// An agent that finds the owner's Oct 1 request file at launch treats
    /// it as old, and takes the next press, which comes in a new session.
    func testTheOwnersRequestFileDoesNotBlockTheNextPress() async throws {
        let dir = try makeTemporaryDirectory()
        let owners = #"{"requestedAt":1790885010.281976,"session":"","afterWriter":"CF3BFB22-E232-4046-9BD8-943A073B5EB0","sequence":30,"afterSnapshot":4068}"#
        try Data(owners.utf8).write(to: dir.appendingPathComponent(RefreshRequestStore.fileName))
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        var taken = await agent.takeRefreshRequest()
        XCTAssertFalse(taken, "made before launch")
        clock.advance(60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken, "the next press is taken")
    }

    /// A press made after a press's answer was written is not named by it,
    /// so it is left for the loop to take. (A scheduled poll's cached
    /// snapshot names no new press at all.) The later press is made on the
    /// press poll's third clock reading, just after its write; the test
    /// checks it landed after the write.
    func testAPressNotAnsweredByThePollIsLeftToTake() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let hook = ClockHook()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {},
                               clock: { hook.read(); return clock.stamp })
        _ = await agent.tick()
        clock.advance(60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let took = await agent.takeRefreshRequest()
        XCTAssertTrue(took)
        let made = RequestBox()
        hook.arm(onRead: 3) { made.set(try? RefreshRequestStore.request(in: dir, at: clock.now)) }
        _ = await agent.tick(userRequested: true)
        let later = try XCTUnwrap(made.value)
        let snapshot = SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json"))
        XCTAssertEqual(later.afterSnapshot, snapshot?.writeSequence, "made just after the answer's write")
        XCTAssertFalse(RefreshState.answers(snapshot, later))
        clock.advance(31)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken, "not answered by that poll, so still a press to take")
    }

    /// A press whose snapshot cannot be written leaves its change pending:
    /// after a restart, the next write that succeeds asks for the reload.
    func testAFailedWriteLeavesThePressedChangePending() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        var agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok(20), ok(30)]), reload: { reloads.increment() },
                               clock: { clock.stamp })
        _ = await agent.tick()
        XCTAssertEqual(reloads.count, 1)
        clock.advance(11 * 60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        let snapshot = dir.appendingPathComponent("snapshot.json")
        try FileManager.default.removeItem(at: snapshot)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false)
        let failed = await agent.tick(userRequested: true)
        XCTAssertNotNil(failed.writeError)
        XCTAssertEqual(reloads.count, 1)
        try FileManager.default.removeItem(at: snapshot)

        agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok(30)]), reload: { reloads.increment() },
                           clock: { clock.stamp })
        clock.advance(60)
        let report = await agent.tick()
        XCTAssertNil(report.writeError)
        XCTAssertEqual(reloads.count, 2, "30% was never shown, so it is still a change")
    }

    /// A press on disk at launch is taken only while it could still be
    /// waiting for its answer: inside its 90 s "Refreshing…" window with no
    /// snapshot naming it. One past the window is old, and not taken; the
    /// next press is, even with the wall clock behind it.
    func testAPressFromBeforeLaunchIsTakenOnlyInsideItsWindow() async throws {
        let inside = try makeTemporaryDirectory()
        try RefreshRequestStore.request(in: inside, at: start.addingTimeInterval(-60))
        let clock = ManualClock(start)
        let live = UsageAgent(directory: inside, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        let takenInside = await live.takeRefreshRequest()
        XCTAssertTrue(takenInside, "60 s old and unanswered: still waiting")

        let past = try makeTemporaryDirectory()
        try RefreshRequestStore.request(in: past, at: start.addingTimeInterval(-120))
        let agent = UsageAgent(directory: past, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        let taken = await agent.takeRefreshRequest()
        XCTAssertFalse(taken, "120 s old: past its window")
        try RefreshRequestStore.request(in: past, at: start.addingTimeInterval(-180))
        let next = await agent.takeRefreshRequest()
        XCTAssertTrue(next, "the next press is taken, whatever the wall clock says")
    }

    /// After the wall clock is set back an hour, a press still works.
    func testAPressWorksAfterTheClockIsSetBack() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(10)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let first = await agent.takeRefreshRequest()
        XCTAssertTrue(first)
        clock.setWall(start.addingTimeInterval(-3600))
        clock.advance(40)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let second = await agent.takeRefreshRequest()
        XCTAssertTrue(second, "numbered presses do not care about the wall clock")
    }

    /// Press reloads are never held by spacing: presses 31 s and five
    /// minutes apart each get one, and the last one's time is kept across
    /// restarts.
    func testPressReloadsAreNeverHeldBySpacing() async throws {
        let dir = try makeTemporaryDirectory()
        try seedRequests(dir, count: 10)
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                               clock: { clock.stamp })
        let first = try await press(agent, dir, clock)
        XCTAssertTrue(first?.reloadReasons.contains(.user) ?? false, String(describing: first?.reloadReasons))
        XCTAssertEqual(reloads.count, 1)
        clock.advance(31)
        _ = try await press(agent, dir, clock)
        XCTAssertEqual(reloads.count, 2, "31 s later")
        clock.advance(5 * 60)
        _ = try await press(agent, dir, clock)
        XCTAssertEqual(reloads.count, 3, "five minutes later")
        let saved = try XCTUnwrap(state(dir))
        XCTAssertEqual(saved.requests.count, 10, "the seeded background requests only")
        XCTAssertEqual(saved.lastCapExemption?.wall, clock.now, "the last press reload, kept across restarts")
    }

    /// The request file deleted mid-run: the next press starts a new
    /// session at 1 and is still taken.
    func testAPressAfterTheFileIsDeletedIsTaken() async throws {
        let dir = try makeTemporaryDirectory()
        for _ in 0..<5 { try RefreshRequestStore.request(in: dir, at: start.addingTimeInterval(-600)) }
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        try FileManager.default.removeItem(at: dir.appendingPathComponent(RefreshRequestStore.fileName))
        clock.advance(5)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        clock.advance(40)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let next = await agent.takeRefreshRequest()
        XCTAssertTrue(next, "the new session goes on counting")
    }

    /// A small backward clock correction: the agent's next snapshot is
    /// still written (numbered on) and answers the press made after it.
    func testAClockSetBackAFewMinutesStillWritesAndAnswers() async throws {
        let dir = try makeTemporaryDirectory()
        let noon = start
        var old = UsageSnapshot(writtenAt: noon, providers: [])
        old.writeSequence = 5
        try SnapshotStore.write(old, to: dir.appendingPathComponent("snapshot.json"))
        let clock = ManualClock(noon.addingTimeInterval(-300))
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        let request = try RefreshRequestStore.request(in: dir, at: clock.now)
        XCTAssertEqual(request.afterSnapshot, 5)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        clock.advance(1)
        let report = await agent.tick(userRequested: true)
        XCTAssertNil(report.writeError)
        let written = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(written.writeSequence, 6)
        XCTAssertEqual(written.writtenAt, noon.addingTimeInterval(-299))
        XCTAssertTrue(RefreshState.answers(written, request))
    }

    /// The limit note of earlier builds is removed at launch.
    func testTheOldLimitNoteIsRemoved() async throws {
        let dir = try makeTemporaryDirectory()
        let old = dir.appendingPathComponent("refresh-result.json")
        try Data(#"{"status": "capped", "sequence": 1, "nextAllowedAt": 1790000000, "session": "old"}"#.utf8).write(to: old)
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    /// A press's reload is never refused for the reload memory: when its
    /// time cannot be saved, or the memory is in its conservative hour,
    /// launch after launch, the press still reloads once.
    func testAPressReloadsEvenWhenItsTimeCannotBeSaved() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        try seedRequests(dir, count: 10)
        let saver = FlakySaver()
        let reloads = Counter()
        func launch() -> UsageAgent {
            UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                       clock: { clock.stamp }, saveState: saver.save)
        }
        // Saves work at launch, then fail at the press.
        var agent = launch()
        _ = await agent.tick()
        saver.failing = true
        clock.advance(40)
        _ = try await press(agent, dir, clock)
        XCTAssertEqual(reloads.count, 1, "its time could not be saved; it reloads anyway")

        // Locked from launch: the conservative hour; each press still reloads.
        for _ in 0..<2 {
            agent = launch()
            clock.advance(40)
            let report = try await press(agent, dir, clock)
            XCTAssertNotNil(report)
        }
        XCTAssertEqual(reloads.count, 3)

        // Launched while saves failed (conservative), then saves work again.
        agent = launch()
        _ = await agent.tick()  // the state loads (and fails to save) here
        saver.failing = false
        clock.advance(40)
        _ = try await press(agent, dir, clock)
        XCTAssertEqual(reloads.count, 4, "inside the conservative hour, a press still reloads")
        let last = try XCTUnwrap(try log(dir).split(separator: "\n").last)
        XCTAssertTrue(last.contains("kind=press"), String(last))
    }

    /// With reload state that cannot be saved, presses every 31 s each still
    /// reload, across a restart too, and nothing speaks of limits.
    func testPressesInConservativeModeStillReload() async throws {
        let dir = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(ReloadStateStore.fileName),
                                                withIntermediateDirectories: true)
        let clock = ManualClock(start)
        let reloads = Counter()
        var agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                               clock: { clock.stamp })
        _ = await agent.tick()
        XCTAssertEqual(reloads.count, 0, "the launch counts as a reload for the background")
        for press in 0..<20 {
            clock.advance(31)
            if press == 10 {
                agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                                   clock: { clock.stamp })
            }
            try RefreshRequestStore.request(in: dir, at: clock.now)
            if await agent.takeRefreshRequest() { _ = await agent.tick(userRequested: true) }
        }
        XCTAssertEqual(reloads.count, 20, "every press reloads")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("refresh-result.json").path))
    }
}

/// The fixed background cap, as the agent runs it.
final class BudgetAgentTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    /// A busy day: numbers moving every minute and a press every quarter
    /// hour. Each press gets its one reload (the person's own, bounded by
    /// the 30 s debounce). Presses take no tokens and are not counted by the
    /// cap, so background reloads still get the whole bucket: a full bucket
    /// (6) plus the tokens that arrive during the day (39 before its last
    /// minute), 45, under the 47 ceiling.
    func testPressesLeaveTheBackgroundItsWholeBucket() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: AlternatingRunner(), reload: { reloads.increment() },
                               clock: { clock.stamp })
        var presses = 0
        var pressReloads = 0
        var background = 0
        func count(_ report: TickReport) {
            guard !report.reloadReasons.isEmpty else { return }
            if report.reloadReasons.contains(.user) { pressReloads += 1 } else { background += 1 }
        }
        for minute in 0..<(24 * 60) {
            if minute % 15 == 7 {
                try RefreshRequestStore.request(in: dir, at: clock.now)
                if await agent.takeRefreshRequest() {
                    presses += 1
                    count(await agent.tick(userRequested: true))
                }
            } else {
                count(await agent.tick())
            }
            clock.advance(60)
        }
        XCTAssertEqual(presses, 96)
        XCTAssertEqual(pressReloads, presses, "one reload per press")
        XCTAssertEqual(reloads.count, pressReloads + background)
        XCTAssertEqual(background, Int(ReloadBucket.capacity) + Int((24 * 3600 - 1) / ReloadBucket.refill))
        XCTAssertLessThanOrEqual(background, ReloadScheduler.dailyCap)
    }
}

/// Saves the reload state, or fails on demand.
final class FlakySaver: @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    var failing: Bool {
        get { lock.withLock { fail } }
        set { lock.withLock { fail = newValue } }
    }

    func save(_ state: ReloadState, to url: URL) throws {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        try ReloadStateStore.write(state, to: url)
    }
}

/// Write numbers the agent keeps itself, adoption, writer ids.
final class WriterAgentTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func ok() -> Result<RunOutput, RunFailure> {
        .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20)])))
    }

    func snapshotURL(_ dir: URL) -> URL { dir.appendingPathComponent("snapshot.json") }

    func testACorruptNumberOnDiskStartsAgainAtOne() async throws {
        let dir = try makeTemporaryDirectory()
        try SnapshotStore.write(UsageSnapshot(writtenAt: start, providers: [], writeSequence: Int.max), to: snapshotURL(dir))
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        let report = await agent.tick()
        XCTAssertNil(report.writeError)
        XCTAssertEqual(SnapshotStore.read(from: snapshotURL(dir))?.writeSequence, 1)
        XCTAssertEqual(WriterStateStore.read(in: dir)?.lastSequence, 1, "kept by the writer")
    }

    /// Another writer's 9 after this agent's 8: adopted, the next write is 10.
    func testAHigherExternalNumberIsAdoptedNotObeyed() async throws {
        let dir = try makeTemporaryDirectory()
        try WriterStateStore.write(WriterState(lastSequence: 7), in: dir)
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        XCTAssertEqual(SnapshotStore.read(from: snapshotURL(dir))?.writeSequence, 8)
        try SnapshotStore.write(UsageSnapshot(writtenAt: start, providers: [], writeSequence: 9), to: snapshotURL(dir))
        clock.advance(60)
        let report = await agent.tick()
        XCTAssertNil(report.writeError)
        XCTAssertEqual(SnapshotStore.read(from: snapshotURL(dir))?.writeSequence, 10)
        try SnapshotStore.write(UsageSnapshot(writtenAt: start, providers: [], writeSequence: 12), to: snapshotURL(dir))
        clock.advance(60)
        _ = await agent.tick()
        XCTAssertEqual(SnapshotStore.read(from: snapshotURL(dir))?.writeSequence, 13)
        let log = try String(contentsOf: dir.appendingPathComponent(SharedContainer.agentLogFileName), encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "adopted write number").count - 1, 1, "logged once")
    }

    /// The snapshot and writer state deleted, the agent restarted: its
    /// numbers start again, but its new writer id answers the press.
    func testARestartAfterDeletionAnswersAPendingPress() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let first = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        for _ in 0..<5 { _ = await first.tick(); clock.advance(60) }
        let request = try RefreshRequestStore.request(in: dir, at: clock.now)
        XCTAssertEqual(request.afterSnapshot, 5)
        try FileManager.default.removeItem(at: snapshotURL(dir))
        try FileManager.default.removeItem(at: dir.appendingPathComponent(WriterStateStore.fileName))
        let second = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        _ = await second.tick()
        XCTAssertEqual(SnapshotStore.read(from: snapshotURL(dir))?.writeSequence, 1)
        XCTAssertTrue(RefreshState.answers(SnapshotStore.read(from: snapshotURL(dir)), request))
    }

    /// At the last valid number the agent wraps to 1 under a new writer id
    /// and a press waiting on the old id is answered.
    func testTheAgentWrapsUnderANewWriterAndAnswersThePress() async throws {
        let dir = try makeTemporaryDirectory()
        let last = WriterState.maxSequence - 1
        try WriterStateStore.write(WriterState(lastSequence: last), in: dir)
        try SnapshotStore.write(UsageSnapshot(writtenAt: start, providers: [], writeSequence: last, writerId: "OLD"),
                                to: snapshotURL(dir))
        let request = try RefreshRequestStore.request(in: dir, at: start)
        XCTAssertEqual(request.afterWriter, "OLD")
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        let first = await agent.currentWriterId
        _ = await agent.tick()
        let written = try XCTUnwrap(SnapshotStore.read(from: snapshotURL(dir)))
        XCTAssertEqual(written.writeSequence, 1)
        XCTAssertNotEqual(written.writerId, first, "a new id with the wrap")
        let now = await agent.currentWriterId
        XCTAssertEqual(written.writerId, now)
        XCTAssertTrue(RefreshState.answers(written, request))
        clock.advance(60)
        _ = await agent.tick()
        XCTAssertEqual(SnapshotStore.read(from: snapshotURL(dir))?.writeSequence, 2, "numbering goes on from 1")
    }

    func testTheCodexCallLogRefusesALink() throws {
        let dir = try makeTemporaryDirectory()
        let secret = try makeTemporaryDirectory().appendingPathComponent("secret")
        try Data(#"{"version": 1, "calls": []}"#.utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(CodexCallLogStore.fileName),
                                                   withDestinationURL: secret)
        guard case .unreadable = CodexCallLogStore.read(from: dir.appendingPathComponent(CodexCallLogStore.fileName)) else {
            return XCTFail("the call log was read through a link")
        }
    }
}

/// Numbers that move on every run: 20% and 30% in turn.
final class AlternatingRunner: CswapRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func runList(fresh: Bool) async -> Result<RunOutput, RunFailure> {
        let pct = lock.withLock { () -> Double in
            count += 1
            return count % 2 == 0 ? 30 : 20
        }
        return .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, pct)])))
    }
}

/// Turns a test's slow steps on and off.
final class SlowSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// A cswap run that takes `seconds` on the manual clock while slow steps
/// are on.
final class SlowRunner: CswapRunning, @unchecked Sendable {
    let clock: ManualClock
    let slow: SlowSteps
    let seconds: TimeInterval

    init(clock: ManualClock, slow: SlowSteps, seconds: TimeInterval) {
        self.clock = clock
        self.slow = slow
        self.seconds = seconds
    }

    func runList(fresh: Bool) async -> Result<RunOutput, RunFailure> {
        if slow.on { clock.advance(seconds) }
        return .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20)])))
    }
}
