import XCTest
import UsageCore
@testable import UsageAgentCore

/// A press re-measures every account: the agent runs
/// `cswap list --json --fresh`, where a background poll runs the cached
/// `cswap list --json`. A cswap from before `--fresh` refuses the option;
/// the press is then measured once more with the cached list, and the
/// reload log says so. Any other failure is answered as before.
final class PressFreshTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    static let noFreshLine = "press: cswap has no --fresh; measured with the cached list"

    /// What argparse prints, and its exit code, when the installed cswap
    /// is given an option it does not know.
    let rejected: Result<RunOutput, RunFailure> = .success(RunOutput(
        exitCode: 2, stdout: Data(),
        stderr: Data("usage: cswap <command> [args] [options]\ncswap: error: unrecognized arguments: --fresh\n".utf8)))

    func ok() -> Result<RunOutput, RunFailure> {
        .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20), ("2", false, 10)])))
    }

    func log(_ dir: URL) -> [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent(SharedContainer.agentLogFileName), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func fallbackLines(_ dir: URL) -> [String] {
        log(dir).filter { $0.contains("--fresh") }
    }

    func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func press(_ agent: UsageAgent, _ dir: URL, _ clock: ManualClock) async throws -> TickReport {
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken, "the press is taken")
        return await agent.tick(userRequested: true)
    }

    /// A fake cswap that appends its arguments to `argv` and prints a
    /// two-account list; with `knowsFresh` false it refuses `--fresh` the
    /// way the installed cswap does, before printing anything.
    func fakeCswap(knowsFresh: Bool) throws -> (home: URL, argv: URL) {
        let files = try makeTemporaryDirectory()
        let argv = files.appendingPathComponent("argv")
        let json = files.appendingPathComponent("list.json")
        try listJSON([("1", true, 20), ("2", false, 10)]).write(to: json)
        let refuse = knowsFresh ? "" : """
            for a in "$@"; do
              if [ "$a" = "--fresh" ]; then
                echo 'usage: cswap <command> [args] [options]' >&2
                echo 'cswap: error: unrecognized arguments: --fresh' >&2
                exit 2
              fi
            done
            """
        let home = try makeCswapHome("""
            printf '%s\\n' "$*" >> '\(argv.path)'
            \(refuse)
            cat '\(json.path)'
            """)
        return (home, argv)
    }

    /// Through the real runner: background polls run `list --json`, a press
    /// runs `list --json --fresh`.
    func testAPressAsksCswapToMeasureEveryAccountNow() async throws {
        let dir = try makeTemporaryDirectory()
        let cswap = try fakeCswap(knowsFresh: true)
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ProcessCswapRunner(locator: CswapLocator(home: cswap.home)),
                               reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(20)
        let report = try await press(agent, dir, clock)
        XCTAssertEqual(report.status, .ok)
        XCTAssertNil(report.error)
        clock.advance(60)
        _ = await agent.tick()
        XCTAssertEqual(try lines(cswap.argv), ["list --json", "list --json --fresh", "list --json"])
        XCTAssertEqual(fallbackLines(dir), [], "a cswap that knows --fresh needs no fallback")
    }

    /// The same through the scripted runner: one fresh run per press,
    /// never one for a background poll.
    func testOnlyAPressAsksForAFreshList() async throws {
        let dir = try makeTemporaryDirectory()
        let runner = ScriptedRunner([ok()])
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: runner, reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(20)
        _ = try await press(agent, dir, clock)
        clock.advance(60)
        _ = await agent.tick()
        XCTAssertEqual(runner.freshFlags, [false, true, false])
    }

    /// A cswap without `--fresh` refuses it before doing anything; the
    /// press is measured with the cached list at once, its numbers are
    /// written, and the reload log gets one line saying so. The next
    /// background poll runs once, as ever, and logs nothing.
    func testAPressOnACswapWithoutFreshIsMeasuredWithTheCachedList() async throws {
        let dir = try makeTemporaryDirectory()
        let cswap = try fakeCswap(knowsFresh: false)
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ProcessCswapRunner(locator: CswapLocator(home: cswap.home)),
                               reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(20)
        let report = try await press(agent, dir, clock)
        XCTAssertEqual(report.status, .ok)
        XCTAssertNil(report.error, "the refusal is not shown as an error")
        XCTAssertEqual(try lines(cswap.argv), ["list --json", "list --json --fresh", "list --json"])
        let snapshot = try XCTUnwrap(SnapshotStore.read(from: dir.appendingPathComponent(SharedContainer.snapshotFileName)))
        XCTAssertEqual(snapshot.provider(CswapListMapper.provider)?.status, .ok)
        XCTAssertEqual(snapshot.provider(CswapListMapper.provider)?.accounts.map(\.id), ["1", "2"])
        XCTAssertEqual(fallbackLines(dir), ["\(ISODate.format(clock.now)) \(Self.noFreshLine)"])

        clock.advance(60)
        _ = await agent.tick()
        XCTAssertEqual(try lines(cswap.argv).count, 4, "a background poll runs cswap once")
        XCTAssertEqual(try lines(cswap.argv).last, "list --json")
        XCTAssertEqual(fallbackLines(dir).count, 1, "and logs nothing about --fresh")
    }

    /// The fallback runs once: if the cached list fails too, that failure
    /// is the press's answer.
    func testTheFallbackRunsOnce() async throws {
        let dir = try makeTemporaryDirectory()
        let runner = ScriptedRunner([ok(), rejected])
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: runner, reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(20)
        let report = try await press(agent, dir, clock)
        XCTAssertEqual(runner.freshFlags, [false, true, false])
        XCTAssertEqual(report.status, .error)
        XCTAssertEqual(report.error, "cswap exited with code 2")
        XCTAssertEqual(fallbackLines(dir).count, 1)
    }

    /// Any other failure of a press's fresh run takes the existing error
    /// path: no second run, no log line, and the same error a background
    /// poll would show for it.
    func testAnyOtherFailureOfAPressFollowsTheErrorPath() async throws {
        let failures: [(String, Result<RunOutput, RunFailure>)] = [
            ("a traceback", .success(RunOutput(exitCode: 1, stdout: Data(), stderr: Data(
                "Traceback (most recent call last):\nRuntimeError: keychain locked\n".utf8)))),
            ("a failure naming --fresh", .success(RunOutput(exitCode: 1, stdout: Data(), stderr: Data(
                "RuntimeError: --fresh failed: network unreachable\n".utf8)))),
            ("unrecognized arguments without --fresh", .success(RunOutput(exitCode: 2, stdout: Data(), stderr: Data(
                "cswap: error: unrecognized arguments: --freshness\n".utf8)))),
            ("an error envelope", .success(RunOutput(exitCode: 1, stdout: Data(
                #"{"schemaVersion": 1, "error": {"type": "X", "message": "No accounts yet"}}"#.utf8)))),
            ("a timeout", .failure(.timedOut(50))),
            ("a zero exit", .success(RunOutput(exitCode: 0, stdout: Data("oops".utf8), stderr: Data(
                "cswap: error: unrecognized arguments: --fresh\n".utf8)))),
        ]
        for (name, failure) in failures {
            let dir = try makeTemporaryDirectory()
            let runner = ScriptedRunner([ok(), failure])
            let clock = ManualClock(start)
            let agent = UsageAgent(directory: dir, runner: runner, reload: {}, clock: { clock.stamp })
            _ = await agent.tick()
            clock.advance(20)
            let report = try await press(agent, dir, clock)
            XCTAssertEqual(runner.freshFlags, [false, true], "\(name): no second run")
            guard case .failure(let expected) = CswapInterpreter.interpret(failure) else {
                return XCTFail("\(name) is not a failure")
            }
            XCTAssertEqual(report.status, .error, name)
            XCTAssertEqual(report.error, expected.reason, name)
            XCTAssertEqual(fallbackLines(dir), [], name)
        }
    }

    /// A press made just before a scheduled poll, before the loop took it,
    /// makes that poll its answer: one cswap run, fresh, under a press's
    /// rules. The background decision does not run (a control agent without
    /// the press reloads for the same change) and, answered in time for the
    /// intent, it adds no completion reload.
    func testAPressJustBeforeAScheduledPollMakesThatPollItsFreshAnswer() async throws {
        func run(pressing: Bool) async throws -> (runner: ScriptedRunner, reloads: Int, request: RefreshRequest?,
                                                    agent: UsageAgent, dir: URL) {
            let dir = try makeTemporaryDirectory()
            let runner = ScriptedRunner([
                .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20)]))),
                .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 30)]))),
            ])
            let reloads = Counter()
            let clock = ManualClock(start)
            let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
            _ = await agent.tick()
            clock.advance(11 * 60)
            let request = pressing ? try RefreshRequestStore.request(in: dir, at: clock.now) : nil
            _ = await agent.tick()
            return (runner, reloads.count, request, agent, dir)
        }
        let control = try await run(pressing: false)
        XCTAssertEqual(control.runner.freshFlags, [false, false])
        XCTAssertEqual(control.reloads, 2, "without a press the background decision shows the change")

        let pressed = try await run(pressing: true)
        XCTAssertEqual(pressed.runner.freshFlags, [false, true], "the scheduled poll's one run is fresh")
        let request = try XCTUnwrap(pressed.request)
        let snapshot = SnapshotStore.read(from: pressed.dir.appendingPathComponent(SharedContainer.snapshotFileName))
        XCTAssertTrue(RefreshState.answers(snapshot?.mark, request), "its snapshot answers the press")
        let again = await pressed.agent.takeRefreshRequest()
        XCTAssertFalse(again, "the press is marked answered")
        XCTAssertEqual(pressed.reloads, 1, "a press's rules: no background reload, no completion reload")
    }

    /// A press made while a scheduled poll's cached run is under way is
    /// not answered by those numbers: the next cswap run is a fresh one,
    /// and no snapshot answering the press exists until it has run.
    func testAPressDuringAScheduledPollIsAnsweredByAFreshRunAfterIt() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let runner = PressingRunner(dir: dir, clock: clock, pressOnRun: 2)
        let agent = UsageAgent(directory: dir, runner: runner, reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(60)
        _ = await agent.tick()
        // The loop then looks for a press, as it does between polls.
        if await agent.takeRefreshRequest() { _ = await agent.tick(userRequested: true) }
        let request = try XCTUnwrap(runner.request)
        XCTAssertEqual(runner.runs.map(\.fresh), [false, false, true], "the run after the press is fresh")
        XCTAssertEqual(runner.runs.last?.pressAnswered, false, "nothing answered the press before its fresh run")
        let snapshot = SnapshotStore.read(from: dir.appendingPathComponent(SharedContainer.snapshotFileName))
        XCTAssertTrue(RefreshState.answers(snapshot?.mark, request))
        let again = await agent.takeRefreshRequest()
        XCTAssertFalse(again, "the press is marked answered")
    }

    /// A press made after a scheduled poll's last look but before its write
    /// is not marked answered by the cached snapshot, though that snapshot
    /// is newer than the press: the loop takes it and measures it fresh.
    /// The press is made on the poll's second clock reading (the first
    /// dates its run, the second its snapshot), and the test checks it
    /// landed in that window: after the last look (no fresh run in the
    /// poll) and before the write (the snapshot is newer than the press).
    func testAPressAfterAScheduledPollsLastLookIsLeftForAFreshRun() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let hook = ClockHook()
        let runner = ScriptedRunner([ok()])
        let agent = UsageAgent(directory: dir, runner: runner, reload: {}, clock: { hook.read(); return clock.stamp })
        _ = await agent.tick()
        clock.advance(60)
        let made = RequestBox()
        hook.arm(onRead: 2) { made.set(try? RefreshRequestStore.request(in: dir, at: clock.now)) }
        _ = await agent.tick()
        let request = try XCTUnwrap(made.value)
        XCTAssertEqual(runner.freshFlags, [false, false], "made after the poll's last look")
        let snapshot = SnapshotStore.read(from: dir.appendingPathComponent(SharedContainer.snapshotFileName))
        XCTAssertTrue(RefreshState.answers(snapshot?.mark, request), "made before the poll's write")
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken, "the cached snapshot did not mark it answered")
        _ = await agent.tick(userRequested: true)
        XCTAssertEqual(runner.freshFlags, [false, false, true])
    }

    /// A press taken and not yet answered when a scheduled poll runs is
    /// answered by that poll, fresh.
    func testAPressTakenButNotYetAnsweredIsAnsweredFreshByTheNextPoll() async throws {
        let dir = try makeTemporaryDirectory()
        let runner = ScriptedRunner([ok()])
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: runner, reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(40)
        let request = try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        _ = await agent.tick()
        XCTAssertEqual(runner.freshFlags, [false, true])
        let snapshot = SnapshotStore.read(from: dir.appendingPathComponent(SharedContainer.snapshotFileName))
        XCTAssertTrue(RefreshState.answers(snapshot?.mark, request))
        clock.advance(40)
        let again = await agent.takeRefreshRequest()
        XCTAssertFalse(again, "the press is marked answered")
    }

    /// The fallback is a press's alone: a background poll that gets the
    /// same refusal (it never asks for --fresh) shows it as an error.
    func testABackgroundPollNeverFallsBack() async throws {
        let dir = try makeTemporaryDirectory()
        let runner = ScriptedRunner([rejected])
        let agent = UsageAgent(directory: dir, runner: runner, reload: {}, clock: fixedClock(start))
        let report = await agent.tick()
        XCTAssertEqual(runner.freshFlags, [false])
        XCTAssertEqual(report.status, .error)
        XCTAssertEqual(report.error, "cswap exited with code 2")
        XCTAssertEqual(fallbackLines(dir), [])
    }
}

/// A cswap that presses the refresh button while its run numbered
/// `pressOnRun` is under way, and records for each run whether it was fresh
/// and whether a snapshot answering that press was already on disk.
final class PressingRunner: CswapRunning, @unchecked Sendable {
    struct Run: Equatable {
        var fresh: Bool
        var pressAnswered: Bool
    }

    let dir: URL
    let clock: ManualClock
    let pressOnRun: Int
    private let lock = NSLock()
    private var recorded: [Run] = []
    private var pressed: RefreshRequest?

    init(dir: URL, clock: ManualClock, pressOnRun: Int) {
        self.dir = dir
        self.clock = clock
        self.pressOnRun = pressOnRun
    }

    var runs: [Run] { lock.withLock { recorded } }
    var request: RefreshRequest? { lock.withLock { pressed } }

    func runList(fresh: Bool) async -> Result<RunOutput, RunFailure> {
        let onDisk = SnapshotStore.read(from: dir.appendingPathComponent(SharedContainer.snapshotFileName))
        let number = lock.withLock { () -> Int in
            recorded.append(Run(fresh: fresh, pressAnswered: pressed.map { RefreshState.answers(onDisk?.mark, $0) } ?? false))
            return recorded.count
        }
        if number == pressOnRun {
            let request = try? RefreshRequestStore.request(in: dir, at: clock.now)
            lock.withLock { pressed = request }
        }
        return .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20)])))
    }
}

/// Runs an action on the clock reading numbered `n` after arming.
final class ClockHook: @unchecked Sendable {
    private let lock = NSLock()
    private var countdown = 0
    private var action: (() -> Void)?

    func arm(onRead n: Int, _ action: @escaping () -> Void) {
        lock.withLock {
            countdown = n
            self.action = action
        }
    }

    func read() {
        let due = lock.withLock { () -> (() -> Void)? in
            guard action != nil else { return nil }
            countdown -= 1
            guard countdown == 0 else { return nil }
            defer { action = nil }
            return action
        }
        due?()
    }
}

final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RefreshRequest?
    func set(_ value: RefreshRequest?) { lock.withLock { stored = value } }
    var value: RefreshRequest? { lock.withLock { stored } }
}
