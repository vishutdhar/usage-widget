import XCTest
import UsageCore
@testable import UsageAgentCore

final class UsageAgentTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func ok(_ accounts: [(String, Bool, Double)]) -> Result<RunOutput, RunFailure> {
        .success(RunOutput(exitCode: 0, stdout: listJSON(accounts)))
    }

    /// The reload lines of the agent's log (budget checks are logged there too).
    func logLines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            .filter { $0.contains(" reload ") }
    }

    func testFirstTickWritesTheSnapshotAndReloads() async throws {
        let dir = try makeTemporaryDirectory()
        let reloads = Counter()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20)])]),
                               reload: { reloads.increment() }, clock: { clock.stamp })

        let report = await agent.tick()

        XCTAssertEqual(report.reloadReasons, [.first])
        XCTAssertEqual(report.status, .ok)
        XCTAssertNil(report.writeError)
        XCTAssertEqual(reloads.count, 1)
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(snapshot.writtenAt, start)
        XCTAssertEqual(snapshot.providers.map(\.provider), ["claude"])
        XCTAssertEqual(try snapshot.providers[at: 0].source, "cswap-list")
        XCTAssertEqual(try snapshot.providers[at: 0].accounts.map(\.label), ["user1@example.com"])
        let log = logLines(dir.appendingPathComponent("reload-log.txt"))
        XCTAssertEqual(log.count, 1)
        XCTAssertTrue(try log[at: 0].contains("reasons=first urgent=yes"), "\(log)")
    }

    func testUnchangedTickRewritesButDoesNotReload() async throws {
        let dir = try makeTemporaryDirectory()
        let reloads = Counter()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20.1)]), ok([("1", true, 20.3)])]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(60)
        let report = await agent.tick()

        XCTAssertEqual(report.reloadReasons, [])
        XCTAssertEqual(reloads.count, 1)
        XCTAssertEqual(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json"))?.writtenAt, start + 60,
                       "the snapshot is rewritten every tick so its age shows the agent is alive")
        XCTAssertEqual(logLines(dir.appendingPathComponent("reload-log.txt")).count, 1)
    }

    func testOrdinaryChangeWaitsTenMinutesAndLogs() async throws {
        let dir = try makeTemporaryDirectory()
        let reloads = Counter()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir,
                               runner: ScriptedRunner([ok([("1", true, 20)]), ok([("1", true, 23)])]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        var held: TickReport?
        for _ in 1...9 {
            clock.advance(60)
            held = await agent.tick()
            XCTAssertEqual(held?.reloadReasons, [])
        }
        XCTAssertEqual(held?.pending, true)
        XCTAssertEqual(reloads.count, 1, "23% is written every minute but not worth a reload yet")
        XCTAssertEqual(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json"))?.writtenAt, start + 9 * 60)

        clock.advance(60)
        let fired = await agent.tick()
        XCTAssertEqual(fired.reloadReasons, [.percent])
        XCTAssertEqual(reloads.count, 2)
        let log = logLines(dir.appendingPathComponent("reload-log.txt"))
        XCTAssertEqual(log.count, 2)
        XCTAssertTrue(try log[at: 1].contains("reasons=percent urgent=no"), "\(log)")
    }

    func testUrgentChangeWaitsTenMinutes() async throws {
        let dir = try makeTemporaryDirectory()
        let reloads = Counter()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir,
                               runner: ScriptedRunner([ok([("1", true, 20), ("2", false, 5)]),
                                                       ok([("1", false, 20), ("2", true, 5)])]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        for _ in 1...9 {
            clock.advance(60)
            let report = await agent.tick()
            XCTAssertEqual(report.reloadReasons, [])
        }
        clock.advance(60)
        let fired = await agent.tick()
        XCTAssertEqual(fired.reloadReasons, [.active])
        XCTAssertEqual(reloads.count, 2)
    }

    func testFailureIsAnUrgentStatusChangeAndKeepsLastGoodAccounts() async throws {
        let dir = try makeTemporaryDirectory()
        let reloads = Counter()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir,
                               runner: ScriptedRunner([ok([("1", true, 20)]), .failure(.notFound)]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(60)
        let failed = await agent.tick()
        XCTAssertEqual(failed.status, .error)
        XCTAssertEqual(failed.error, "cswap not found")
        XCTAssertEqual(failed.reloadReasons, [], "urgent, but only a minute after the last request")
        XCTAssertEqual(failed.pending, true)
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(try snapshot.providers[at: 0].status, .error)
        XCTAssertEqual(try snapshot.providers[at: 0].accounts.map(\.label), ["user1@example.com"])
        XCTAssertEqual(try snapshot.providers[at: 0].accounts[at: 0].fetchedAt, ISODate.parse("2026-09-27T10:00:00Z"))

        clock.advance(9 * 60)
        let fired = await agent.tick()
        XCTAssertEqual(fired.reloadReasons, [.status, .errorText], "and the reason line appears")
        clock.advance(60)
        let again = await agent.tick()
        XCTAssertEqual(again.reloadReasons, [])
        XCTAssertEqual(reloads.count, 2)
    }

    func testRestartKeepsTheSchedulersMemory() async throws {
        let dir = try makeTemporaryDirectory()
        let reloads = Counter()
        let clock = ManualClock(start)
        let first = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20)])]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await first.tick()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("reload-state.json").path))

        clock.advance(60)
        let second = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20)])]),
                                reload: { reloads.increment() }, clock: { clock.stamp })
        let report = await second.tick()
        XCTAssertEqual(report.reloadReasons, [], "a restart with unchanged data spends no reload")
        XCTAssertEqual(reloads.count, 1)
    }

    func testAHeldChangeSurvivesARestart() async throws {
        let dir = try makeTemporaryDirectory()
        let reloads = Counter()
        let clock = ManualClock(start)
        let first = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20)]), ok([("1", true, 40)])]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await first.tick()
        clock.advance(120)
        let held = await first.tick()
        XCTAssertEqual(held.pending, true)

        clock.advance(58 * 60)
        let second = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 40)])]),
                                reload: { reloads.increment() }, clock: { clock.stamp })
        let fired = await second.tick()
        XCTAssertEqual(fired.reloadReasons, [.percent], "the new process still knows 40% was never requested")
        XCTAssertEqual(reloads.count, 2)
    }

    func testRestartAfterFailureStillHasTheLastGoodAccounts() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let first = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20)])]),
                               reload: {}, clock: { clock.stamp })
        _ = await first.tick()
        let second = UsageAgent(directory: dir, runner: ScriptedRunner([.failure(.timedOut(50))]),
                                reload: {}, clock: { clock.stamp })
        _ = await second.tick()
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        XCTAssertEqual(try snapshot.providers[at: 0].error, "cswap did not answer within 50 s")
        XCTAssertEqual(try snapshot.providers[at: 0].accounts.count, 1)
    }

    func testWriteErrorsAreMasked() async throws {
        let dir = try makeTemporaryDirectory().appendingPathComponent("alex@example.com")
        let now = start
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20)])]),
                               reload: {}, clock: fixedClock(now))
        let report = await agent.tick()
        let text = try XCTUnwrap(report.writeError)
        XCTAssertFalse(text.contains("alex@example.com"), text)
        XCTAssertTrue(text.contains("ale***@***.com"), text)
    }

    func testAnUnsavableReloadStateEntersConservativeMode() async throws {
        let dir = try makeTemporaryDirectory()
        let stateURL = dir.appendingPathComponent("reload-state.json")
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        let reloads = Counter()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir,
                               runner: ScriptedRunner([ok([("1", true, 20), ("2", false, 5)]),
                                                       ok([("1", false, 20), ("2", true, 5)])]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        let first = await agent.tick()
        XCTAssertEqual(first.reloadReasons, [], "the launch itself counts as a request in conservative mode")
        XCTAssertTrue(first.stateError?.hasPrefix("Reload state could not be saved: ") ?? false, "\(first)")

        var fired: [Int] = []
        for minute in 1...60 {
            clock.advance(60)
            let report = await agent.tick()
            if !report.reloadReasons.isEmpty { fired.append(minute) }
            XCTAssertNotNil(report.stateError, "retried and still failing at minute \(minute)")
        }
        XCTAssertEqual(fired, [60], "the first reload waits an hour after launch")
        XCTAssertEqual(reloads.count, 1)
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        XCTAssertTrue(try snapshot.providers[at: 0].error?.hasPrefix("Reload state could not be saved: ") ?? false)
        XCTAssertEqual(try snapshot.providers[at: 0].status, .ok, "cswap itself is fine")
    }

    /// Restarting cannot buy reloads while the state cannot be saved.
    func testRepeatedRestartsWithAnUnwritableStateNeverReloadWithinTheHour() async throws {
        let dir = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("reload-state.json"),
                                                withIntermediateDirectories: true)
        let reloads = Counter()
        let clock = ManualClock(start)
        for restart in 0..<29 {
            let pct = Double(10 + restart * 3)
            let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, pct)])]),
                                   reload: { reloads.increment() }, clock: { clock.stamp })
            _ = await agent.tick()
            clock.advance(59)
        }
        XCTAssertEqual(reloads.count, 0, "29 restarts in under half an hour, zero reloads")
    }

    func testTheStateIsSavedOnceTheProblemIsFixed() async throws {
        let dir = try makeTemporaryDirectory()
        let stateURL = dir.appendingPathComponent("reload-state.json")
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20)])]),
                               reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        try FileManager.default.removeItem(at: stateURL)
        clock.advance(60)
        let fixed = await agent.tick()
        XCTAssertNil(fixed.stateError, "the dirty state is written on the next poll")
        guard case .loaded = ReloadStateStore.read(from: stateURL) else { return XCTFail("state was not saved") }
        clock.advance(60)
        _ = await agent.tick()
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent("snapshot.json")))
        XCTAssertNil(try snapshot.providers[at: 0].error)
    }

    func testAStateFileFromTheOlderBuildIsMigratedWithoutAnError() async throws {
        let dir = try makeTemporaryDirectory()
        let old = start.timeIntervalSince1970 - 3600
        try JSONSerialization.data(withJSONObject: ["lastRequestAt": old, "pending": false, "requests": [old]])
            .write(to: dir.appendingPathComponent("reload-state.json"))
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20)])]),
                               reload: {}, clock: { clock.stamp })
        let report = await agent.tick()
        XCTAssertNil(report.stateError)
        XCTAssertEqual(report.reloadReasons, [.first])
        guard case .loaded(let saved) = ReloadStateStore.read(from: dir.appendingPathComponent("reload-state.json")) else {
            return XCTFail("state not saved")
        }
        XCTAssertEqual(saved.requests.count, 2, "the migrated request still counts")
    }

    func testHelperWarningsAreCounted() async throws {
        let dir = try makeTemporaryDirectory()
        var helper = RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20)]))
        helper.leftHelper = true
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir,
                               runner: ScriptedRunner([.success(helper), ok([("1", true, 20)]), .success(helper)]),
                               reload: {}, clock: { clock.stamp })
        var counts: [Int] = []
        for _ in 0..<3 {
            counts.append(await agent.tick().helperWarnings)
            clock.advance(60)
        }
        XCTAssertEqual(counts, [1, 1, 2])
    }

    /// A state file that reads but cannot be replaced (read only and
    /// locked, as Finder's Locked box does) must throttle restarts just as
    /// an unreadable one does.
    func testALockedReadableStateFileStillThrottlesRestarts() async throws {
        let dir = try makeTemporaryDirectory()
        let stateURL = dir.appendingPathComponent("reload-state.json")
        let longAgo = SchedulerClock(wall: start.addingTimeInterval(-86_400), continuous: 0, boot: nil)
        try ReloadStateStore.write(ReloadState(lastRequest: longAgo, requests: [longAgo]), to: stateURL)
        XCTAssertEqual(chmod(stateURL.path, 0o444), 0)
        XCTAssertEqual(chflags(stateURL.path, UInt32(UF_IMMUTABLE)), 0, "set the uchg flag")
        defer { _ = chflags(stateURL.path, 0); _ = chmod(stateURL.path, 0o644) }
        guard case .loaded = ReloadStateStore.read(from: stateURL) else { return XCTFail("the file must still read") }

        let reloads = Counter()
        let clock = ManualClock(start)
        var errors: [String?] = []
        for restart in 0..<29 {
            let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, Double(10 + restart * 3))])]),
                                   reload: { reloads.increment() }, clock: { clock.stamp })
            errors.append(await agent.tick().stateError)
            clock.advance(59)
        }
        XCTAssertEqual(reloads.count, 0, "29 restarts in under half an hour, zero reloads")
        XCTAssertTrue(errors.allSatisfy { $0?.hasPrefix("Reload state could not be saved: ") ?? false }, "\(errors[0] ?? "nil")")
    }

    func testUnwritableDirectoryIsReportedAndDoesNotReload() async throws {
        let dir = try makeTemporaryDirectory().appendingPathComponent("gone")
        let reloads = Counter()
        let now = start
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok([("1", true, 20)])]),
                               reload: { reloads.increment() }, clock: fixedClock(now))
        let report = await agent.tick()
        XCTAssertNotNil(report.writeError)
        XCTAssertEqual(reloads.count, 0, "no reload for a snapshot the widget cannot read")
    }
}
