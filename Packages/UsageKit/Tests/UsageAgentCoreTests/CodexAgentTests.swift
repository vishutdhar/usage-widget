import XCTest
import UsageCore
@testable import UsageAgentCore

final class FakeCodex: CodexSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private var found: Bool
    private var rollout: CodexReading?
    /// When set, the rollout reading is made from the poll's time.
    private var rolloutAt: ((Date) -> CodexReading?)?
    private var results: [Result<CodexReading, FetchFailure>]
    /// Answers go round in a circle instead of repeating the last one.
    private let cycle: Bool
    private var calls = 0

    init(found: Bool = true, rollout: CodexReading?, appServer: [Result<CodexReading, FetchFailure>], cycle: Bool = false) {
        self.found = found
        self.rollout = rollout
        self.results = appServer
        self.cycle = cycle
    }

    /// Runs on each look for Codex (a file system check in the real one).
    var onFound: (() -> Void)?
    var codexFound: Bool {
        onFound?()
        return lock.withLock { found }
    }
    var appServerCalls: Int { lock.withLock { calls } }
    func setRollout(_ reading: CodexReading?) { lock.withLock { rollout = reading } }
    func setRolloutAt(_ make: @escaping (Date) -> CodexReading?) { lock.withLock { rolloutAt = make } }
    func rolloutReading(now: Date) -> CodexReading? { lock.withLock { rolloutAt.map { $0(now) } ?? rollout } }
    /// When set, each answer is made at the moment of the call.
    private var answerNow: (() -> Result<CodexReading, FetchFailure>)?
    func setAnswerNow(_ make: @escaping () -> Result<CodexReading, FetchFailure>) { lock.withLock { answerNow = make } }
    func appServerReading() async -> Result<CodexReading, FetchFailure> {
        if let make = lock.withLock({ answerNow }) {
            lock.withLock { calls += 1 }
            return make()
        }
        return next()
    }

    private func next() -> Result<CodexReading, FetchFailure> {
        lock.withLock {
            calls += 1
            if cycle { return results[(calls - 1) % results.count] }
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}

final class CodexAgentTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func weekly(_ pct: Double, at date: Date, source: CodexReading.Source = .rollout, resets: Int? = nil) -> CodexReading {
        CodexReading(source: source, measuredAt: date,
                     windows: [UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: pct,
                                           resetsAt: date.addingTimeInterval(3 * 86_400))],
                     planType: "pro", resetCreditsAvailable: resets)
    }

    func ok() -> Result<RunOutput, RunFailure> {
        .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20)])))
    }

    func codexBlock(_ dir: URL) throws -> ProviderUsage {
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        return try XCTUnwrap(snapshot.provider("codex"))
    }

    func testCodexJoinsTheSnapshotBesideTheCswapAccounts() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: weekly(35, at: start.addingTimeInterval(-30)),
                              appServer: [.success(weekly(37, at: start.addingTimeInterval(-60), source: .appServer, resets: 2))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(snapshot.providers.map(\.provider), ["claude", "codex"])
        let block = try codexBlock(dir)
        XCTAssertEqual(try block.accounts[at: 0].windows.map(\.usedPct), [35], "the newer rollout reading")
        XCTAssertEqual(block.extras["resetCreditsAvailable"], .number(2), "the count from the app-server")
        XCTAssertEqual(codex.appServerCalls, 1, "asked at start")
    }

    func testAnAppServerFailureShowsWhileRolloutDataStays() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: weekly(35, at: start),
                              appServer: [.failure(FetchFailure(reason: "codex app-server did not answer within 20 s"))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        let report = await agent.tick()
        XCTAssertEqual(report.codexError, "codex app-server did not answer within 20 s", "for the status window")
        XCTAssertEqual(report.status, .ok, "the report's own status stays cswap's")
        let block = try codexBlock(dir)
        XCTAssertEqual(block.status, .ok, "a fresh rollout: the failure is the collector's, not a usage status")
        XCTAssertNil(block.error)
        XCTAssertEqual(block.collectorError, "codex app-server did not answer within 20 s")
        XCTAssertEqual(try block.accounts[at: 0].windows.map(\.usedPct), [35])
        let claude = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json"))?.provider("claude"))
        XCTAssertEqual(claude.status, .ok, "a Codex problem never touches the cswap block")
    }

    func testALaterAnswerClearsTheAppServerError() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: weekly(35, at: start),
                              appServer: [.failure(FetchFailure(reason: "codex app-server exited before answering (code 1)")),
                                          .success(weekly(40, at: start.addingTimeInterval(3 * 3600), source: .appServer, resets: 1))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        XCTAssertEqual(try codexBlock(dir).collectorError, "codex app-server exited before answering (code 1)")
        clock.advance(3 * 3600)  // Codex idle: the next call is three hours on
        let report = await agent.tick()
        XCTAssertNil(report.codexError)
        let block = try codexBlock(dir)
        XCTAssertEqual(block.status, .ok)
        XCTAssertNil(block.error)
        XCTAssertNil(block.collectorError)
        XCTAssertEqual(block.source, "app-server", "the answer is newer than the rollout")
        XCTAssertEqual(try block.accounts[at: 0].windows.map(\.usedPct), [40])
        XCTAssertEqual(block.extras["resetCreditsAvailable"], .number(1))
    }

    func testAFailedAskKeepsTheLastResetCount() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil,
                              appServer: [.success(weekly(37, at: start, source: .appServer, resets: 2)),
                                          .failure(FetchFailure(reason: "codex app-server did not answer within 20 s"))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        clock.advance(3 * 3600)  // Codex idle: the next call is three hours on
        _ = await agent.tick()
        let block = try codexBlock(dir)
        XCTAssertEqual(codex.appServerCalls, 2)
        XCTAssertEqual(block.status, .ok, "the last answer is three hours old, inside Codex's four hour line")
        XCTAssertEqual(block.collectorError, "codex app-server did not answer within 20 s")
        XCTAssertEqual(block.extras["resetCreditsAvailable"], .number(2), "the last answer still counts")
        XCTAssertEqual(try block.accounts[at: 0].windows.map(\.usedPct), [37])
    }

    /// Off hides the block from the widget; it stays in the snapshot.
    func testTurningCodexOffHidesItsBlock() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: FakeCodex(rollout: weekly(35, at: start), appServer: [.success(weekly(35, at: start))]))
        _ = await agent.tick()
        await agent.setCodex(nil)
        clock.advance(60)
        _ = await agent.tick()
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(snapshot.providers.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(snapshot.providers.map(\.hidden), [false, true])
        XCTAssertEqual(WidgetContent.make(snapshot: snapshot, at: clock.now).sections.map(\.provider), ["claude"])
    }

    /// Codex changes go through the same scheduler: a band crossing is
    /// urgent (10 minutes), a percent move ordinary (an hour).
    func testCodexChangesFeedTheSameScheduler() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let codex = FakeCodex(rollout: weekly(35, at: start), appServer: [.failure(FetchFailure(reason: "x"))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                               clock: { clock.stamp }, codex: codex)
        _ = await agent.tick()
        XCTAssertEqual(reloads.count, 1, "the first request")

        var fired: [Int] = []
        for minute in 1...12 {
            clock.advance(60)
            codex.setRollout(weekly(minute < 3 ? 39 : 75, at: clock.now))
            let report = await agent.tick()
            if !report.reloadReasons.isEmpty { fired.append(minute) }
        }
        XCTAssertEqual(fired, [10], "39% waits; crossing 70 is urgent and goes ten minutes after the first request")
    }
}

/// Collector trouble is not usage news,
/// clocks cannot promote old readings, and a restart keeps what was shown.
final class CodexAgentRobustnessTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func weekly(_ pct: Double, at date: Date, source: CodexReading.Source = .rollout, resets: Int? = nil) -> CodexReading {
        CodexReading(source: source, measuredAt: date,
                     windows: [UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: pct,
                                           resetsAt: Date(timeIntervalSince1970: 1_790_400_000))],
                     planType: "pro", resetCreditsAvailable: resets)
    }

    func ok() -> Result<RunOutput, RunFailure> {
        .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20)])))
    }

    func codexBlock(_ dir: URL) throws -> ProviderUsage {
        try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json"))?.provider("codex"))
    }

    func codexDimmed(_ dir: URL, at date: Date) throws -> Bool {
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        let section = try XCTUnwrap(WidgetContent.make(snapshot: snapshot, at: date).sections.first { $0.provider == "codex" })
        return try XCTUnwrap(section.accounts.first).dimmed
    }

    /// The wall clock jumps five hours ahead: the Codex numbers, ten
    /// minutes old on the continuous clock, stay bright.
    func testAWallClockJumpForwardDoesNotDimFreshCodexNumbers() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: weekly(35, at: start.addingTimeInterval(-600)),
                              appServer: [.failure(FetchFailure(reason: "offline"))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp }, codex: codex)
        _ = await agent.tick()
        clock.setWall(start.addingTimeInterval(5 * 3600))
        clock.advance(60)
        _ = await agent.tick()
        XCTAssertFalse(try codexDimmed(dir, at: clock.now))
    }

    /// The wall clock goes back five hours: the Codex numbers, five hours
    /// old on the continuous clock, stay dimmed.
    func testAWallClockJumpBackDoesNotFreshenStaleCodexNumbers() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: weekly(35, at: start.addingTimeInterval(-600)),
                              appServer: [.failure(FetchFailure(reason: "offline"))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp }, codex: codex)
        _ = await agent.tick()
        clock.advance(5 * 3600)
        _ = await agent.tick()
        clock.setWall(start)
        clock.advance(60)
        _ = await agent.tick()
        XCTAssertTrue(try codexDimmed(dir, at: clock.now))
    }

    /// A restart after the wall clock went back keeps stale numbers stale:
    /// the reading's age comes from the snapshot's kept age, not from the
    /// wall clock's measurement time.
    func testARestartAfterTheClockWentBackKeepsTheReadingStale() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let first = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: FakeCodex(rollout: weekly(35, at: start.addingTimeInterval(-600)),
                                                appServer: [.failure(FetchFailure(reason: "offline"))]))
        _ = await first.tick()
        clock.advance(5 * 3600)
        _ = await first.tick()
        XCTAssertEqual(try codexBlock(dir).accounts.first?.status, .stale)
        clock.setWall(start)
        clock.advance(60)
        let restarted = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                                   codex: FakeCodex(rollout: nil, appServer: [.failure(FetchFailure(reason: "offline"))]))
        _ = await restarted.tick()
        XCTAssertEqual(try codexBlock(dir).accounts.first?.status, .stale, "five hours old, whatever the wall clock says")
        XCTAssertTrue(try codexDimmed(dir, at: clock.now))
    }

    /// Show Codex turned off while an app-server call is out: the answer,
    /// when it comes, does not make the block visible again.
    func testTurningCodexOffDuringACallKeepsTheBlockHidden() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = SuspendedCodex(reading: weekly(35, at: start, source: .appServer, resets: 2))
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp }, codex: codex)
        let poll = Task { await agent.tick() }
        while !codex.isWaiting { try await Task.sleep(for: .milliseconds(5)) }
        await agent.setCodex(nil)
        codex.answer()
        _ = await poll.value
        let block = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json"))).provider("codex")
        XCTAssertTrue(block == nil || block?.hidden == true, "\(String(describing: block))")
    }

    /// A later app-server answer without the reset count keeps the count
    /// already known, as the plan is kept.
    func testAnAnswerWithoutTheResetCountKeepsTheKnownCount() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer, resets: 2)),
                                                        .success(weekly(36, at: start, source: .appServer, resets: nil))])
        codex.setAnswerNow { [weak self] in
            .success(self!.weekly(codex.appServerCalls <= 1 ? 35 : 36, at: clock.now, source: .appServer,
                                  resets: codex.appServerCalls <= 1 ? 2 : nil))
        }
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp }, codex: codex)
        _ = await agent.tick()
        XCTAssertEqual(try codexBlock(dir).extras["resetCreditsAvailable"], .number(2))
        for _ in 0..<(3 * 60 + 1) {
            clock.advance(60)
            _ = await agent.tick()
        }
        XCTAssertEqual(codex.appServerCalls, 2, "a second answer, without the count")
        XCTAssertEqual(try codexBlock(dir).accounts.first?.windows.map(\.usedPct), [36])
        XCTAssertEqual(try codexBlock(dir).extras["resetCreditsAvailable"], .number(2))
    }

    /// An app-server that fails every other call, beside a rollout that is
    /// always fresh, spends no urgent reload in a whole day.
    func testADayOfAppServerFlappingSpendsNoUrgentReload() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer, resets: 2)),
                                                        .failure(FetchFailure(reason: "codex app-server did not answer within 20 s"))],
                              cycle: true)
        codex.setRolloutAt { [weak self] now in self?.weekly(35, at: now.addingTimeInterval(-30)) }
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        var urgent: [Int] = []
        var errors = 0
        for minute in 1...(24 * 60) {
            clock.advance(60)
            let report = await agent.tick()
            if report.reloadReasons.contains(where: \.isUrgent) { urgent.append(minute) }
            if report.codexError != nil { errors += 1 }
            if minute % 97 == 0 { XCTAssertEqual(try codexBlock(dir).status, .ok, "minute \(minute)") }
        }
        XCTAssertEqual(urgent, [], "no urgent reload after the first")
        XCTAssertGreaterThan(errors, 600, "the failed calls stood for about half the day")
        XCTAssertEqual(codex.appServerCalls, 5, "start, then every six hours for the count")
    }

    /// With Codex idle, the app-server answers every three hours and the
    /// Codex line is four: the account never flips stale and back, so a
    /// whole day spends no urgent reload.
    func testAnIdleDayWithThreeHourAnswersSpendsNoUrgentReload() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [])
        codex.setAnswerNow { [weak self] in
            .success(self!.weekly(35, at: clock.now, source: .appServer, resets: 2))
        }
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        var urgent: [Int] = []
        for minute in 1..<(24 * 60) {
            clock.advance(60)
            let report = await agent.tick()
            if report.reloadReasons.contains(where: \.isUrgent) { urgent.append(minute) }
        }
        XCTAssertEqual(codex.appServerCalls, 8, "every three hours, the whole ceiling")
        XCTAssertEqual(urgent, [])
    }

    /// The cached reading (80%, measured 14:00)
    /// keeps its own time when the clock is set back an hour. The file's
    /// 14:00 event now looks ahead and is skipped, so the parser falls back
    /// to its 13:01 event (60%), which is older than the cache and does
    /// not replace it.
    func testAClockSetBackKeepsTheCachedReading() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: weekly(80, at: start), appServer: [.failure(FetchFailure(reason: "offline"))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        clock.setWall(start.addingTimeInterval(-3600))
        clock.advance(60)
        codex.setRollout(weekly(60, at: start.addingTimeInterval(-59 * 60)))
        _ = await agent.tick()
        let account = try XCTUnwrap(try codexBlock(dir).accounts.first)
        XCTAssertEqual(account.windows.map(\.usedPct), [80])
        XCTAssertEqual(account.fetchedAt, start, "never rebased")
    }

    /// A rollout event newer than the cached reading replaces it.
    func testANewerRolloutEventReplacesTheCache() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: weekly(80, at: start), appServer: [.failure(FetchFailure(reason: "offline"))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        clock.advance(300)
        codex.setRollout(weekly(83, at: start.addingTimeInterval(240)))
        _ = await agent.tick()
        XCTAssertEqual(try codexBlock(dir).accounts.first?.windows.map(\.usedPct), [83])
        codex.setRollout(weekly(81, at: start.addingTimeInterval(240)))
        clock.advance(60)
        _ = await agent.tick()
        XCTAssertEqual(try codexBlock(dir).accounts.first?.windows.map(\.usedPct), [83], "not strictly newer")
    }

    /// Whatever the wall clock says, the cached reading ages by the time
    /// that really passed.
    func testTheCacheAgesByTheContinuousClock() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: weekly(80, at: start), appServer: [.failure(FetchFailure(reason: "offline"))])
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: codex)
        _ = await agent.tick()
        codex.setRollout(nil)
        clock.setWall(start.addingTimeInterval(-3600))
        clock.advance(4 * 3600 + 60)
        _ = await agent.tick()
        let account = try XCTUnwrap(try codexBlock(dir).accounts.first)
        XCTAssertEqual(account.status, .stale, "four hours really passed, though the wall says three")
        XCTAssertEqual(account.fetchedAt, start)
    }

    /// Show Codex off, a poll, a restart, then on again with the day's
    /// calls used up: the numbers and the reset count come back.
    func testOffPollRestartOnKeepsTheNumbers() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let first = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: FakeCodex(rollout: nil, appServer: [.success(weekly(40, at: start, source: .appServer, resets: 2))]))
        _ = await first.tick()
        await first.setCodex(nil)
        clock.advance(60)
        _ = await first.tick()
        let hidden = try codexBlock(dir)
        XCTAssertTrue(hidden.hidden, "kept in the snapshot, hidden")
        XCTAssertEqual(hidden.accounts.first?.windows.map(\.usedPct), [40])

        clock.advance(60)
        let calls = (1...8).map { SchedulerClock(wall: start.addingTimeInterval(Double(-$0 * 60)), continuous: 0, boot: nil) }
        try CodexCallLogStore.write(CodexCallLog(calls: calls.reversed()), to: dir.appendingPathComponent(CodexCallLogStore.fileName))
        let second = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        _ = await second.tick()
        XCTAssertTrue(try codexBlock(dir).hidden, "still off after the restart, still kept")
        let again = FakeCodex(rollout: nil, appServer: [.failure(FetchFailure(reason: "should not be asked"))])
        await second.setCodex(again)
        clock.advance(60)
        _ = await second.tick()
        let block = try codexBlock(dir)
        XCTAssertFalse(block.hidden)
        XCTAssertEqual(block.accounts.first?.windows.map(\.usedPct), [40])
        XCTAssertEqual(block.extras["resetCreditsAvailable"], .number(2))
        XCTAssertEqual(again.appServerCalls, 0)
    }

    /// A home with rollout files and no codex binary, read by the real
    /// collector: nothing can launch an app-server.
    func collectorHome() throws -> (CodexHomeFixture, CodexCollector) {
        let fixture = try CodexHomeFixture()
        return (fixture, CodexCollector(paths: fixture.paths))
    }

    func rollout(_ fixture: CodexHomeFixture, _ name: String, pct: Double, claims: Date, modified: Date) throws {
        let url = try fixture.dayDirectory(start, calendar: .current).appendingPathComponent(name)
        try Data((rateLimitLine(pct: pct, at: ISODate.format(claims)) + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    /// Toggling Show Codex off and on, with a fresh collector as the app
    /// makes one, changes nothing about the reading shown.
    func testTogglingCodexOffAndOnChangesNothing() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let (fixture, collector) = try collectorHome()
        try rollout(fixture, "rollout-a.jsonl", pct: 55, claims: start.addingTimeInterval(-60),
                    modified: start.addingTimeInterval(-60))
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: collector)
        _ = await agent.tick()
        let before = try XCTUnwrap(try codexBlock(dir).accounts.first)
        await agent.setCodex(nil)
        clock.advance(60)
        _ = await agent.tick()
        await agent.setCodex(CodexCollector(paths: fixture.paths))
        clock.advance(60)
        _ = await agent.tick()
        let after = try XCTUnwrap(try codexBlock(dir).accounts.first)
        XCTAssertEqual(after.fetchedAt, before.fetchedAt)
        XCTAssertEqual(after.windows, before.windows)
        XCTAssertEqual(after.fetchedAt, start.addingTimeInterval(-60))
    }

    /// Show Codex off then on, with the day's calls used up: the numbers
    /// and the reset count are kept, and no call is made.
    func testTurningCodexOffAndOnKeepsTheNumbersUnderAFullCeiling() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        // Wall-clock stamps (no boot id) are aged by the wall clock.
        let earlier = (1...7).map { SchedulerClock(wall: start.addingTimeInterval(Double(-$0 * 300)), continuous: 0,
                                                   boot: nil) }.reversed()
        try CodexCallLogStore.write(CodexCallLog(calls: Array(earlier)), to: dir.appendingPathComponent(CodexCallLogStore.fileName))
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer, resets: 2))]))
        _ = await agent.tick()
        await agent.setCodex(nil)
        clock.advance(60)
        _ = await agent.tick()
        let again = FakeCodex(rollout: nil, appServer: [.failure(FetchFailure(reason: "should not be asked"))])
        await agent.setCodex(again)
        clock.advance(60)
        _ = await agent.tick()
        XCTAssertEqual(again.appServerCalls, 0, "eight calls already today")
        let block = try codexBlock(dir)
        XCTAssertEqual(try XCTUnwrap(block.accounts.first).windows.map(\.usedPct), [35])
        XCTAssertEqual(block.extras["resetCreditsAvailable"], .number(2))
    }

    /// Turning Codex on again with calls to spare asks the app-server once.
    func testTurningCodexOnWithRoomMakesOneCall() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))]))
        _ = await agent.tick()
        await agent.setCodex(nil)
        let again = FakeCodex(rollout: nil, appServer: [.success(weekly(39, at: start, source: .appServer))])
        await agent.setCodex(again)
        clock.advance(60)
        _ = await agent.tick()
        clock.advance(60)
        _ = await agent.tick()
        XCTAssertEqual(again.appServerCalls, 1)
    }

    /// The last app-server answer time is kept in the snapshot, whichever
    /// source won the windows, and survives a restart.
    func testTheLastAnswerTimeIsKeptInTheSnapshot() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let answered = start.addingTimeInterval(-60)
        let first = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: answered, source: .appServer))])
        first.setRolloutAt { [weak self] now in self?.weekly(40, at: now.addingTimeInterval(-10)) }
        _ = await UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                             codex: first).tick()
        XCTAssertEqual(try codexBlock(dir).source, "rollout")
        XCTAssertEqual(try codexBlock(dir).extras["appServerCheckedAt"], .string(ISODate.format(answered)))
        clock.advance(60)
        _ = await UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                             codex: FakeCodex(rollout: nil, appServer: [.failure(FetchFailure(reason: "offline"))])).tick()
        XCTAssertEqual(try codexBlock(dir).extras["appServerCheckedAt"], .string(ISODate.format(answered)))
    }

    /// A restart with no rollout files and no network keeps the last Codex
    /// block, with its old measurement time and reset count.
    func testARestartOfflineKeepsTheLastCodexBlock() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let first = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: FakeCodex(rollout: weekly(35, at: start.addingTimeInterval(-60)),
                                                appServer: [.success(weekly(37, at: start.addingTimeInterval(-120),
                                                                            source: .appServer, resets: 2))]))
        _ = await first.tick()

        clock.advance(300)
        let offline = FakeCodex(rollout: nil, appServer: [.failure(FetchFailure(reason: "offline"))])
        let second = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                                codex: offline)
        let report = await second.tick()
        let block = try codexBlock(dir)
        let account = try XCTUnwrap(block.accounts.first)
        XCTAssertEqual(account.windows.map(\.usedPct), [35])
        XCTAssertEqual(account.fetchedAt, start.addingTimeInterval(-60), "the old as of")
        XCTAssertEqual(account.status, .ok, "six minutes old")
        XCTAssertEqual(block.status, .ok)
        XCTAssertEqual(block.extras["resetCreditsAvailable"], .number(2))
        XCTAssertEqual(block.extras["planType"], .string("pro"))
        XCTAssertEqual(report.codexError, "offline")

        // And the ordinary staleness rules then apply.
        clock.advance(4 * 3600)
        _ = await second.tick()
        XCTAssertEqual(try codexBlock(dir).accounts.first?.status, .stale)
    }

    /// A snapshot written before the wall clock was set back holds a
    /// reading dated ahead; after the restart it keeps its time and ages
    /// from the restart.
    func testAFutureDatedSeedAgesFromTheRestart() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start.addingTimeInterval(4 * 3600))
        let first = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                               codex: FakeCodex(rollout: nil, appServer: [.success(weekly(41, at: clock.now, source: .appServer, resets: 1))]))
        _ = await first.tick()

        clock.setWall(start)
        let second = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp },
                                codex: FakeCodex(rollout: nil, appServer: [.failure(FetchFailure(reason: "offline"))]))
        _ = await second.tick()
        XCTAssertEqual(try codexBlock(dir).accounts.first?.fetchedAt, start.addingTimeInterval(4 * 3600),
                       "its own time, never rebased")
        clock.advance(4 * 3600 + 300)
        _ = await second.tick()
        XCTAssertEqual(try codexBlock(dir).accounts.first?.status, .stale)
    }
}

final class CodexPreferenceTests: XCTestCase {
    /// "Show Codex" starts on when ~/.codex exists, and a person's choice
    /// wins after that.
    func testDefaultFollowsTheCodexFolderUntilChosen() {
        XCTAssertTrue(CodexPreference.resolve(stored: nil, codexHomeExists: true))
        XCTAssertFalse(CodexPreference.resolve(stored: nil, codexHomeExists: false))
        XCTAssertFalse(CodexPreference.resolve(stored: false, codexHomeExists: true))
        XCTAssertTrue(CodexPreference.resolve(stored: true, codexHomeExists: false))
        XCTAssertEqual(CodexPreference.key, "showCodex")
    }
}

/// An app-server that answers only when the test says so.
final class SuspendedCodex: CodexSourcing, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Result<CodexReading, FetchFailure>, Never>?
    let reading: CodexReading

    init(reading: CodexReading) {
        self.reading = reading
    }

    var codexFound: Bool { true }
    func rolloutReading(now: Date) -> CodexReading? { nil }
    func appServerReading() async -> Result<CodexReading, FetchFailure> {
        await withCheckedContinuation { continuation in lock.withLock { waiting = continuation } }
    }

    var isWaiting: Bool { lock.withLock { waiting != nil } }
    func answer() {
        let continuation = lock.withLock { () -> CheckedContinuation<Result<CodexReading, FetchFailure>, Never>? in
            let c = waiting
            waiting = nil
            return c
        }
        continuation?.resume(returning: .success(reading))
    }
}
