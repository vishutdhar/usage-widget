import XCTest
import UsageCore
@testable import UsageAgentCore

/// The refresh button's intent writes the request and returns at once, so
/// WidgetKit's reload after it shows "Refreshing…". The agent then asks for
/// one reload of its own once the snapshot answering the press is written,
/// whichever way it is answered, and only then: that reload brings the
/// fresh numbers and the new "as of".
final class PressReloadTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func ok(_ pct: Double = 20, fetchedAt: Date? = nil) -> Result<RunOutput, RunFailure> {
        .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, pct)],
                                                         fetchedAt: ISODate.format(fetchedAt ?? start))))
    }

    func pressLines(_ dir: URL) -> [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent(SharedContainer.agentLogFileName), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init).filter { $0.contains("kind=press") }
    }

    func snapshot(_ dir: URL) -> UsageSnapshot? {
        SnapshotStore.read(from: dir.appendingPathComponent(SharedContainer.snapshotFileName))
    }

    enum AnswerPath: String, CaseIterable {
        /// The loop takes the press and runs a fresh poll for it.
        case pressRun
        /// A second press inside the 30 s debounce: the last snapshot again.
        case debounced
        /// A scheduled poll finds the press waiting and is its answer.
        case scheduledPoll
    }

    /// Each way a press is answered asks for exactly one reload, logged as
    /// a press, once the answer is written; the next quiet poll asks for
    /// nothing more.
    func testEveryAnswerPathRequestsExactlyOnePressReload() async throws {
        for path in AnswerPath.allCases {
            let dir = try makeTemporaryDirectory()
            let clock = ManualClock(start)
            let reloads = Counter()
            let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                                   clock: { clock.stamp })
            _ = await agent.tick()
            clock.advance(11 * 60)
            var before = reloads.count
            var pressesBefore = pressLines(dir).count
            let request: RefreshRequest
            switch path {
            case .pressRun:
                request = try RefreshRequestStore.request(in: dir, at: clock.now)
                let taken = await agent.takeRefreshRequest()
                XCTAssertTrue(taken)
                _ = await agent.tick(userRequested: true)
            case .debounced:
                try RefreshRequestStore.request(in: dir, at: clock.now)
                let taken = await agent.takeRefreshRequest()
                XCTAssertTrue(taken)
                _ = await agent.tick(userRequested: true)
                before = reloads.count
                pressesBefore = pressLines(dir).count
                clock.advance(5)
                request = try RefreshRequestStore.request(in: dir, at: clock.now)
                let again = await agent.takeRefreshRequest()
                XCTAssertFalse(again, "inside the debounce")
            case .scheduledPoll:
                request = try RefreshRequestStore.request(in: dir, at: clock.now)
                _ = await agent.tick()
            }
            XCTAssertTrue(RefreshState.answers(snapshot(dir), request), path.rawValue)
            XCTAssertEqual(reloads.count - before, 1, "\(path.rawValue): one reload for the press")
            XCTAssertEqual(pressLines(dir).count - pressesBefore, 1, "\(path.rawValue): logged as a press")
            clock.advance(60)
            let quiet = await agent.tick()
            XCTAssertEqual(quiet.reloadReasons, [], path.rawValue)
            XCTAssertEqual(reloads.count - before, 1, "\(path.rawValue): nothing more")
        }
    }

    /// A second press 10 s after the first is inside the debounce: no
    /// second cswap run, the last snapshot answers it, and it gets its own
    /// reload all the same.
    func testASecondPressTenSecondsLaterGetsTheDebouncedAnswerAndAReload() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let runner = ScriptedRunner([ok()])
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        _ = await agent.tick(userRequested: true)
        let afterFirst = reloads.count
        let calls = runner.calls
        clock.advance(10)
        let second = try RefreshRequestStore.request(in: dir, at: clock.now)
        let again = await agent.takeRefreshRequest()
        XCTAssertFalse(again, "inside the debounce")
        XCTAssertEqual(runner.calls, calls, "no second cswap run")
        XCTAssertTrue(RefreshState.answers(snapshot(dir), second), "the debounced answer")
        XCTAssertEqual(reloads.count, afterFirst + 1, "and a reload for it")
        XCTAssertEqual(pressLines(dir).count, 2, "one press line for each press")
    }

    /// No reload goes for a press the agent never answers: one whose answer
    /// cannot be written, however often the agent looks again, and one on
    /// disk from before launch, which counts as old and is never taken.
    func testAPressTheAgentNeverAnswersGetsNoReload() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                               clock: { clock.stamp })
        _ = await agent.tick()
        let first = reloads.count
        let url = dir.appendingPathComponent(SharedContainer.snapshotFileName)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        clock.advance(60)
        let request = try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        _ = await agent.tick(userRequested: true)
        for _ in 0..<5 {
            clock.advance(10)
            _ = await agent.takeRefreshRequest()
            _ = await agent.tick()
        }
        XCTAssertFalse(RefreshState.answers(snapshot(dir), request))
        XCTAssertEqual(reloads.count, first, "never answered, never reloaded")
        XCTAssertEqual(pressLines(dir), [])

        let other = try makeTemporaryDirectory()
        try RefreshRequestStore.request(in: other, at: clock.now.addingTimeInterval(-120))
        let restarted = UsageAgent(directory: other, runner: ScriptedRunner([ok()]), reload: { reloads.increment() },
                                   clock: { clock.stamp })
        for _ in 0..<3 {
            _ = await restarted.tick()
            let none = await restarted.takeRefreshRequest()
            XCTAssertFalse(none, "made before launch, past its window")
            clock.advance(60)
        }
        XCTAssertEqual(pressLines(other), [], "no press reload for a press past its window at launch")
    }

    /// The agent restarted between a press and its answer (the intent has
    /// returned and the widget says "Refreshing…"). A press still inside
    /// its 90 s window that no snapshot names is taken as a live press: the
    /// first poll runs fresh under press rules, asks for the press reload,
    /// and the footer clears. One that a snapshot already names, or one
    /// past its window, is old: no fresh run, no press reload, and the
    /// footer shows the last measured time.
    func testARestartBetweenAPressAndItsAnswerStillAnswersIt() async throws {
        let measuredBefore = start.addingTimeInterval(-600)
        for (age, named, live) in [(20.0, false, true), (20.0, true, false), (120.0, false, false)] {
            let name = "pressed \(Int(age)) s before launch\(named ? ", already answered" : "")"
            let dir = try makeTemporaryDirectory()
            try SnapshotStore.write(UsageSnapshot(writtenAt: measuredBefore, providers: [
                ProviderUsage(provider: CswapListMapper.provider, source: CswapListMapper.source, status: .ok,
                              accounts: [AccountUsage(id: "1", label: "a", active: true, fetchedAt: measuredBefore,
                                                      windows: [UsageWindow(kind: .weekly, name: "7d",
                                                                            windowSeconds: 604_800, usedPct: 10)])]),
            ], writeSequence: 3, writerId: "OLD"), to: dir.appendingPathComponent(SharedContainer.snapshotFileName))
            let request = try RefreshRequestStore.request(in: dir, at: start.addingTimeInterval(-age))
            if named {
                var answered = try XCTUnwrap(snapshot(dir))
                answered.answeredPress = AnsweredPress(request)
                try SnapshotStore.write(answered, to: dir.appendingPathComponent(SharedContainer.snapshotFileName))
            }
            let clock = ManualClock(start)
            let runner = ScriptedRunner([ok(40, fetchedAt: start)])
            let reloads = Counter()
            let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
            let report = await agent.tick()
            let content = WidgetContent.make(snapshot: snapshot(dir), at: clock.now, refresh: request)
            if live {
                XCTAssertEqual(runner.freshFlags, [true], "\(name): the first poll runs fresh")
                XCTAssertTrue(report.reloadReasons.contains(.user), "\(name): with the press reload")
                XCTAssertEqual(pressLines(dir).count, 1, name)
                XCTAssertTrue(RefreshState.answers(snapshot(dir), request), name)
                XCTAssertEqual(content.refreshFooter, RefreshFooter.none, "\(name): the footer clears")
                XCTAssertEqual(content.footerTime(for: content.sections.flatMap(\.accounts)), start, name)
            } else {
                XCTAssertEqual(runner.freshFlags, [false], "\(name): no fresh run")
                XCTAssertFalse(report.reloadReasons.contains(.user), name)
                XCTAssertEqual(pressLines(dir), [], "\(name): no press reload")
                XCTAssertEqual(content.refreshFooter, RefreshFooter.none, "\(name): no Refreshing")
            }
            let again = await agent.takeRefreshRequest()
            XCTAssertFalse(again, "\(name): not taken again")
        }
    }

    /// With the day's background requests at the ceiling, a press is
    /// answered fresh and reloaded, and a second press 10 s later gets the
    /// debounced answer and its own reload too: the cap holds neither.
    func testADebouncedAnswerReloadsAtTheCap() async throws {
        let dir = try makeTemporaryDirectory()
        let recent = (0..<ReloadScheduler.dailyCap).map { i in
            SchedulerClock(wall: start.addingTimeInterval(Double(-60 - i * 60)), continuous: 0, boot: nil)
        }
        try ReloadStateStore.write(ReloadState(lastRequest: recent.first, requests: recent),
                                   to: dir.appendingPathComponent(ReloadStateStore.fileName))
        let clock = ManualClock(start)
        let runner = ScriptedRunner([ok()])
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
        clock.advance(5)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        _ = await agent.tick(userRequested: true)
        XCTAssertEqual(runner.freshFlags, [true], "press A, measured fresh")
        XCTAssertEqual(reloads.count, 1, "press A reloaded at the cap")
        clock.advance(10)
        let second = try RefreshRequestStore.request(in: dir, at: clock.now)
        let again = await agent.takeRefreshRequest()
        XCTAssertFalse(again, "inside the debounce")
        XCTAssertTrue(RefreshState.answers(snapshot(dir), second), "press B answered from the last snapshot")
        XCTAssertEqual(reloads.count, 2, "and reloaded at the cap")
        XCTAssertEqual(pressLines(dir).count, 2)
    }

    /// With the reload state unwritable, a press is answered and reloaded,
    /// and a second press 10 s later gets the debounced answer and its own
    /// reload too: neither waits on its record being saved.
    func testADebouncedAnswerReloadsWhileTheStateCannotBeSaved() async throws {
        let dir = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(ReloadStateStore.fileName),
                                                withIntermediateDirectories: true)
        let clock = ManualClock(start)
        let runner = ScriptedRunner([ok()])
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
        let first = await agent.tick()
        XCTAssertNotNil(first.stateError, "the state cannot be saved")
        clock.advance(60)
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        _ = await agent.tick(userRequested: true)
        let afterFirst = reloads.count
        XCTAssertEqual(pressLines(dir).count, 1, "press A reloaded")
        clock.advance(10)
        let second = try RefreshRequestStore.request(in: dir, at: clock.now)
        let again = await agent.takeRefreshRequest()
        XCTAssertFalse(again, "inside the debounce")
        XCTAssertTrue(RefreshState.answers(snapshot(dir), second), "press B answered from the last snapshot")
        XCTAssertEqual(reloads.count, afterFirst + 1, "and reloaded though nothing can be saved")
        XCTAssertEqual(pressLines(dir).count, 2)
    }

    /// The footer across one press, the intent's write first: "Refreshing…"
    /// between the press and the answer (the agent's snapshot from before
    /// the press does not answer it), then, with the answer and its reload,
    /// the plain footer dated from the fresh measurement.
    func testTheFooterSaysRefreshingUntilTheAnswerThenShowsTheFreshTime() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let pressedAt = start.addingTimeInterval(11 * 60)
        let measured = pressedAt.addingTimeInterval(1)
        let reloads = Counter()
        let agent = UsageAgent(directory: dir,
                               runner: ScriptedRunner([ok(20, fetchedAt: start.addingTimeInterval(-300)),
                                                       ok(40, fetchedAt: measured)]),
                               reload: { reloads.increment() }, clock: { clock.stamp })
        _ = await agent.tick()
        clock.advance(11 * 60)
        let request = try RefreshRequestStore.press(in: dir, at: clock.now)
        let waiting = WidgetContent.make(snapshot: snapshot(dir), at: clock.now.addingTimeInterval(0.5), refresh: request)
        XCTAssertEqual(waiting.refreshFooter, .refreshing, "between the press and the answer")
        let before = reloads.count

        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        clock.advance(2)
        _ = await agent.tick(userRequested: true)
        XCTAssertEqual(reloads.count, before + 1, "the agent's reload brings the answer")
        let answered = WidgetContent.make(snapshot: snapshot(dir), at: clock.now, refresh: request)
        XCTAssertEqual(answered.refreshFooter, RefreshFooter.none)
        XCTAssertEqual(answered.footerTime(for: answered.sections.flatMap(\.accounts)), measured,
                       "the fresh measurement's time")
    }
}
