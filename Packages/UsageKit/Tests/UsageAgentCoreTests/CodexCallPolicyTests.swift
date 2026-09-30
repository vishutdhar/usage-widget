import XCTest
import UsageCore
@testable import UsageAgentCore

/// When the agent may launch `codex app-server`: once at start, then only
/// while Codex is idle (no rollout reading within an hour) and three hours
/// after the last call, or every six hours for the reset count, and never
/// more than eight times in a day.
final class CodexCallPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func stamp(_ seconds: TimeInterval) -> SchedulerClock {
        SchedulerClock(wall: t0.addingTimeInterval(seconds), continuous: 1_000_000_000_000 + UInt64(seconds * 1e9),
                       boot: "test")
    }

    func reason(calls: [TimeInterval], first: Bool = false, rolloutAgo: TimeInterval?, at now: TimeInterval) -> CodexCallPolicy.Reason? {
        CodexCallPolicy.reason(calls: calls.map(stamp), firstOfLaunch: first,
                               newestRollout: rolloutAgo.map { t0.addingTimeInterval(now - $0) }, now: stamp(now))
    }

    func testTheFirstCallOfALaunchGoesAhead() {
        XCTAssertEqual(reason(calls: [], first: true, rolloutAgo: 10, at: 0), .start)
        XCTAssertEqual(reason(calls: [0], first: true, rolloutAgo: 10, at: 60), .start, "a restart calls once")
    }

    func testFreshRolloutsHoldTheCallUntilTheCountRefresh() {
        XCTAssertNil(reason(calls: [0], rolloutAgo: 30, at: 3 * 3600))
        XCTAssertNil(reason(calls: [0], rolloutAgo: 30, at: 6 * 3600 - 1))
        XCTAssertEqual(reason(calls: [0], rolloutAgo: 30, at: 6 * 3600), .countRefresh)
    }

    func testAnIdleCodexAllowsACallThreeHoursAfterTheLast() {
        XCTAssertNil(reason(calls: [0], rolloutAgo: nil, at: 3 * 3600 - 1))
        XCTAssertEqual(reason(calls: [0], rolloutAgo: nil, at: 3 * 3600), .codexIdle)
        XCTAssertEqual(reason(calls: [0], rolloutAgo: 5 * 3600, at: 3 * 3600), .codexIdle)
    }

    /// Idle means no rollout reading measured within the last sixty minutes.
    func testIdleStartsSixtyMinutesAfterTheLastRolloutReading() {
        XCTAssertNil(reason(calls: [0], rolloutAgo: 3600, at: 3 * 3600))
        XCTAssertEqual(reason(calls: [0], rolloutAgo: 3601, at: 3 * 3600), .codexIdle)
    }

    func testEightCallsInADayHoldEverything() {
        let eight = (0..<8).map { TimeInterval($0) * 60 }
        XCTAssertNil(reason(calls: eight, first: true, rolloutAgo: nil, at: 3600), "not even at start")
        XCTAssertNil(reason(calls: eight, rolloutAgo: nil, at: 7 * 3600), "nor for the count")
        XCTAssertEqual(reason(calls: Array(eight.prefix(7)), first: true, rolloutAgo: nil, at: 3600), .start)
        // The first leaves the day 24 hours after it was made.
        XCTAssertNil(reason(calls: eight, rolloutAgo: nil, at: 24 * 3600 - 1))
        XCTAssertEqual(reason(calls: eight, rolloutAgo: nil, at: 24 * 3600), .countRefresh)
    }

    func testTheNextEligibleTime() {
        XCTAssertEqual(CodexCallPolicy.nextEligible(calls: [stamp(0)], now: stamp(600)), t0.addingTimeInterval(3 * 3600))
        let eight = (0..<8).map { stamp(TimeInterval($0) * 3 * 3600 / 8) }
        XCTAssertEqual(CodexCallPolicy.nextEligible(calls: eight, now: stamp(3 * 3600)), t0.addingTimeInterval(24 * 3600),
                       "held by the ceiling until the oldest call is a day old")
        XCTAssertEqual(CodexCallPolicy.nextEligible(calls: [], now: stamp(5)), t0.addingTimeInterval(5))
    }
}

final class CodexCallAgentTests: XCTestCase {
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

    func agent(_ dir: URL, _ clock: ManualClock, _ codex: FakeCodex) -> UsageAgent {
        UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp }, codex: codex)
    }

    func run(_ agent: UsageAgent, _ clock: ManualClock, minutes: Int) async {
        for _ in 0..<minutes {
            clock.advance(60)
            _ = await agent.tick()
        }
    }

    /// While Codex runs, rollouts carry the windows: one call at start, then
    /// one every six hours for the reset count.
    func testWhileCodexRunsTheAppServerIsCalledAtStartAndEverySixHours() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer, resets: 2))])
        codex.setRolloutAt { [weak self] now in self?.weekly(35, at: now.addingTimeInterval(-30)) }
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        await run(agent, clock, minutes: 6 * 60 - 1)
        XCTAssertEqual(codex.appServerCalls, 1)
        await run(agent, clock, minutes: 1)
        XCTAssertEqual(codex.appServerCalls, 2, "the six hour count refresh")
        await run(agent, clock, minutes: 18 * 60)
        XCTAssertEqual(codex.appServerCalls, 5, "0, 6, 12, 18 and 24 hours")
    }

    /// With Codex idle, a call every three hours keeps the windows current.
    func testWhileCodexIsIdleCallsComeEveryThreeHours() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: weekly(35, at: start), appServer: [.success(weekly(35, at: start, source: .appServer))])
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        await run(agent, clock, minutes: 12 * 60)
        XCTAssertEqual(codex.appServerCalls, 5, "0, 3, 6, 9 and 12 hours")
    }

    /// The reset count shown follows the six hourly refresh.
    func testTheResetCountRefreshesEverySixHours() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer, resets: 2)),
                                                        .success(weekly(35, at: start, source: .appServer, resets: 1))])
        codex.setRolloutAt { [weak self] now in self?.weekly(35, at: now.addingTimeInterval(-30)) }
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        await run(agent, clock, minutes: 6 * 60 - 1)
        let before = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json"))?.provider("codex"))
        XCTAssertEqual(before.extras["resetCreditsAvailable"], .number(2))
        await run(agent, clock, minutes: 1)
        let after = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json"))?.provider("codex"))
        XCTAssertEqual(after.extras["resetCreditsAvailable"], .number(1))
    }

    /// Ten restarts in an hour make eight calls; the ceiling is on disk.
    func testRestartsCannotBreakTheDailyCeiling() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        for _ in 0..<10 {
            _ = await agent(dir, clock, codex).tick()
            clock.advance(300)
        }
        XCTAssertEqual(codex.appServerCalls, 8)
        clock.advance(24 * 3600 - 10 * 300)
        _ = await agent(dir, clock, codex).tick()
        XCTAssertEqual(codex.appServerCalls, 9, "the first call has left the day")
    }

    /// No log and a folder it cannot be written to: the record before the
    /// call fails, so no call goes, however often the agent restarts.
    func testAnAbsentLogInAReadOnlyFolderNeverLetsACallThrough() async throws {
        let dir = try makeTemporaryDirectory()
        XCTAssertEqual(chmod(dir.path, 0o555), 0)
        defer { chmod(dir.path, 0o755) }
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        for _ in 0..<9 {
            let report = await agent(dir, clock, codex).tick()
            XCTAssertNotNil(report.codexCallsError)
            clock.advance(300)
        }
        XCTAssertEqual(codex.appServerCalls, 0)
    }

    /// A launch that could not write the log counts as a call: once the
    /// folder is writable again, the next call still waits its spacing.
    func testALaunchThatCouldNotWriteTheLogCountsAsACall() async throws {
        let dir = try makeTemporaryDirectory()
        XCTAssertEqual(chmod(dir.path, 0o555), 0)
        defer { chmod(dir.path, 0o755) }
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        XCTAssertEqual(chmod(dir.path, 0o755), 0)
        await run(agent, clock, minutes: 3 * 60 - 1)
        XCTAssertEqual(codex.appServerCalls, 0, "the launch was the call")
        await run(agent, clock, minutes: 1)
        XCTAssertEqual(codex.appServerCalls, 1, "idle Codex, three hours after the launch")
    }

    /// The log could be written at launch but not later: no call goes until
    /// it can be written again.
    func testAWriteFailureAfterStartStopsFurtherCalls() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        XCTAssertEqual(codex.appServerCalls, 1)
        XCTAssertEqual(chmod(dir.path, 0o555), 0)
        await run(agent, clock, minutes: 7 * 60)
        XCTAssertEqual(codex.appServerCalls, 1, "two calls were due; neither could be recorded")
        XCTAssertEqual(chmod(dir.path, 0o755), 0)
        await run(agent, clock, minutes: 1)
        XCTAssertEqual(codex.appServerCalls, 2, "recorded again, so called again")
    }

    func writeLog(_ text: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(CodexCallLogStore.fileName))
    }

    /// A corrupt log is taken as a full day: no call for 24 hours.
    func testACorruptLogCountsAsAFullDay() async throws {
        let dir = try makeTemporaryDirectory()
        try writeLog("{not json", in: dir)
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        await run(agent, clock, minutes: 24 * 60 - 1)
        XCTAssertEqual(codex.appServerCalls, 0)
        await run(agent, clock, minutes: 1)
        XCTAssertEqual(codex.appServerCalls, 1)
    }

    /// Eight calls, then the log is damaged, then a restart: still no ninth
    /// call inside the day.
    func testEightCallsThenACorruptLogThenARestartMakeNoNinth() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        for _ in 0..<8 {
            _ = await agent(dir, clock, codex).tick()
            clock.advance(300)
        }
        XCTAssertEqual(codex.appServerCalls, 8)
        try writeLog(#"{"version":1,"calls":"#, in: dir)
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        await run(agent, clock, minutes: 23 * 60)
        XCTAssertEqual(codex.appServerCalls, 8)
    }

    func testALogFromAnotherVersionCountsAsAFullDay() async throws {
        let dir = try makeTemporaryDirectory()
        try writeLog(#"{"version":99,"calls":[]}"#, in: dir)
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        _ = await agent(dir, clock, codex).tick()
        XCTAssertEqual(codex.appServerCalls, 0)
    }

    /// The build before the log called every 15 minutes. With no log but a
    /// snapshot whose Codex numbers came from the app-server within the
    /// day, that day counts as full from that answer.
    func testAnUpgradeFromTheFifteenMinuteBuildSeedsAFullDay() async throws {
        let dir = try makeTemporaryDirectory()
        let answered = start.addingTimeInterval(-2 * 3600)
        try SnapshotStore.write(UsageSnapshot(writtenAt: answered, providers: [
            ProviderUsage(provider: "codex", source: "app-server", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: answered,
                             windows: weekly(35, at: answered).windows),
            ]),
        ]), to: dir.appendingPathComponent("snapshot.json"))
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        await run(agent, clock, minutes: 22 * 60 - 1)
        XCTAssertEqual(codex.appServerCalls, 0)
        await run(agent, clock, minutes: 1)
        XCTAssertEqual(codex.appServerCalls, 1, "a day after that answer")
    }

    /// The windows came from a rollout, but the snapshot says when the
    /// app-server last answered: that answer seeds the day.
    func testARolloutBackedSnapshotSeedsFromItsLastAnswerTime() async throws {
        let dir = try makeTemporaryDirectory()
        let answered = start.addingTimeInterval(-2 * 3600)
        try SnapshotStore.write(UsageSnapshot(writtenAt: start.addingTimeInterval(-60), providers: [
            ProviderUsage(provider: "codex", source: "rollout", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: start.addingTimeInterval(-60),
                             windows: weekly(35, at: start).windows),
            ], extras: ["appServerCheckedAt": .string(ISODate.format(answered)), "resetCreditsAvailable": .number(1)]),
        ]), to: dir.appendingPathComponent("snapshot.json"))
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        await run(agent, clock, minutes: 22 * 60 - 1)
        XCTAssertEqual(codex.appServerCalls, 0)
        await run(agent, clock, minutes: 1)
        XCTAssertEqual(codex.appServerCalls, 1)
    }

    /// A 15 minute build snapshot backed by a rollout carries no answer
    /// time; that build asked every 15 minutes, so the block's measurement
    /// time stands in.
    func testALegacyRolloutBackedSnapshotWithACountSeedsFromItsMeasurement() async throws {
        let dir = try makeTemporaryDirectory()
        let written = start.addingTimeInterval(-3600)
        try SnapshotStore.write(UsageSnapshot(writtenAt: written, providers: [
            ProviderUsage(provider: "codex", source: "rollout", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: written,
                             windows: weekly(35, at: start).windows),
            ], extras: ["resetCreditsAvailable": .number(1), "planType": .string("pro")]),
        ]), to: dir.appendingPathComponent("snapshot.json"))
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        await run(agent, clock, minutes: 23 * 60 - 1)
        XCTAssertEqual(codex.appServerCalls, 0)
        await run(agent, clock, minutes: 1)
        XCTAssertEqual(codex.appServerCalls, 1)
    }

    /// A 15 minute build snapshot whose windows came from a rollout and
    /// whose reset count is null still seeds the day, from its measurement.
    func testALegacyRolloutBackedSnapshotWithoutACountSeedsFromItsMeasurement() async throws {
        let dir = try makeTemporaryDirectory()
        let measured = start.addingTimeInterval(-3600)
        try SnapshotStore.write(UsageSnapshot(writtenAt: start.addingTimeInterval(-30), providers: [
            ProviderUsage(provider: "codex", source: "rollout", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: measured,
                             windows: weekly(35, at: start).windows),
            ], extras: ["resetCreditsAvailable": .null, "planType": .string("pro")]),
        ]), to: dir.appendingPathComponent("snapshot.json"))
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        let agent = agent(dir, clock, codex)
        _ = await agent.tick()
        await run(agent, clock, minutes: 23 * 60 - 1)
        XCTAssertEqual(codex.appServerCalls, 0)
        await run(agent, clock, minutes: 1)
        XCTAssertEqual(codex.appServerCalls, 1)
    }

    func testAnOldAppServerSnapshotDoesNotHoldTheStart() async throws {
        let dir = try makeTemporaryDirectory()
        let answered = start.addingTimeInterval(-25 * 3600)
        try SnapshotStore.write(UsageSnapshot(writtenAt: answered, providers: [
            ProviderUsage(provider: "codex", source: "app-server", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: answered,
                             windows: weekly(35, at: answered).windows),
            ]),
        ]), to: dir.appendingPathComponent("snapshot.json"))
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        _ = await agent(dir, clock, codex).tick()
        XCTAssertEqual(codex.appServerCalls, 1)
    }

    /// A log that reads but cannot be saved (a read-only folder) is as
    /// untrustworthy as one that cannot be read: the launch counts as a
    /// call, or every restart would launch the app-server unrecorded.
    func testALogThatReadsButCannotBeSavedIsConservativeToo() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let old = SchedulerClock(wall: start.addingTimeInterval(-20 * 3600), continuous: 1, boot: "other")
        try CodexCallLogStore.write(CodexCallLog(calls: [old]), to: dir.appendingPathComponent(CodexCallLogStore.fileName))
        XCTAssertEqual(chmod(dir.path, 0o555), 0)
        defer { chmod(dir.path, 0o755) }
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        for _ in 0..<3 {
            _ = await agent(dir, clock, codex).tick()
            clock.advance(60)
        }
        XCTAssertEqual(codex.appServerCalls, 0)
    }

    func testTheReportSaysWhenCodexWasCheckedAndWhenNext() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let codex = FakeCodex(rollout: nil, appServer: [.success(weekly(35, at: start, source: .appServer))])
        let agent = agent(dir, clock, codex)
        let first = await agent.tick()
        XCTAssertEqual(first.codexCheckedAt, start)
        XCTAssertEqual(first.codexNextCheck, start.addingTimeInterval(3 * 3600))
        XCTAssertNil(first.codexCallsError)
    }
}
