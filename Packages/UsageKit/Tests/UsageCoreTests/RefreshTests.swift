import XCTest
@testable import UsageCore

/// The widget's refresh button: the intent writes a request, the widget
/// says "Refreshing…" until the agent answers or 90 s pass.
final class RefreshRequestTests: XCTestCase {
    let t0 = utc(2026, 9, 28, 16, 8, 0)

    func testTheRequestIsWrittenWholeAndReadBack() throws {
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: FileManager.default.temporaryDirectory, create: true)
        try RefreshRequestStore.request(in: dir, at: t0)
        let written = try XCTUnwrap(RefreshRequestStore.read(in: dir))
        XCTAssertEqual(written.requestedAt, t0)
        XCTAssertEqual(written.sequence, 1)
        try RefreshRequestStore.request(in: dir, at: t0.addingTimeInterval(40))
        XCTAssertEqual(RefreshRequestStore.read(in: dir)?.requestedAt, t0.addingTimeInterval(40))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [RefreshRequestStore.fileName],
                       "written by rename: no temporary file is left")
        XCTAssertEqual(RefreshRequestStore.fileName, "refresh-request.json")
    }

    func testAMissingOrDamagedRequestReadsAsNone() throws {
        let dir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                              appropriateFor: FileManager.default.temporaryDirectory, create: true)
        XCTAssertNil(RefreshRequestStore.read(in: dir))
        try Data("{".utf8).write(to: dir.appendingPathComponent(RefreshRequestStore.fileName))
        XCTAssertNil(RefreshRequestStore.read(in: dir))
    }

    /// Pending until the agent writes the snapshot after the one the press
    /// saw (by write number, not by clock), or 90 s pass.
    func testARequestIsPendingUntilTheAgentAnswersOrNinetySecondsPass() {
        let request = RefreshRequest(requestedAt: t0, afterSnapshot: 5)
        XCTAssertTrue(RefreshState.pending(request, snapshot: SnapshotMark(writer: "", sequence: 5), at: t0.addingTimeInterval(10)))
        XCTAssertTrue(RefreshState.pending(request, snapshot: SnapshotMark(writer: "", sequence: 5), at: t0.addingTimeInterval(89)))
        XCTAssertFalse(RefreshState.pending(request, snapshot: SnapshotMark(writer: "", sequence: 5), at: t0.addingTimeInterval(90)),
                       "after 90 s the footer goes back to as of")
        XCTAssertFalse(RefreshState.pending(request, snapshot: SnapshotMark(writer: "", sequence: 6), at: t0.addingTimeInterval(10)),
                       "the agent wrote the next snapshot")
        XCTAssertFalse(RefreshState.pending(nil, snapshot: SnapshotMark(writer: "", sequence: 5), at: t0))
        XCTAssertTrue(RefreshState.pending(request, snapshot: nil, at: t0.addingTimeInterval(1)))
    }

    func testTheWidgetSaysRefreshingAndPlansTheEndOfIt() {
        let snapshot = UsageSnapshot(writtenAt: t0.addingTimeInterval(-50), providers: [], writeSequence: 5)
        let request = RefreshRequest(requestedAt: t0, afterSnapshot: 5)
        XCTAssertTrue(WidgetContent.make(snapshot: snapshot, at: t0.addingTimeInterval(5), refresh: request).refreshing)
        XCTAssertFalse(WidgetContent.make(snapshot: snapshot, at: t0.addingTimeInterval(95), refresh: request).refreshing)
        XCTAssertFalse(WidgetContent.make(snapshot: snapshot, at: t0.addingTimeInterval(5)).refreshing)
        let plan = TimelinePlan.plan(for: snapshot, now: t0.addingTimeInterval(5), refresh: request)
        XCTAssertTrue(plan.entries.contains(t0.addingTimeInterval(RefreshState.window)), "\(plan.entries)")
        let quiet = TimelinePlan.plan(for: snapshot, now: t0.addingTimeInterval(95), refresh: request)
        XCTAssertFalse(quiet.entries.contains(t0.addingTimeInterval(RefreshState.window)))
    }

    func testAReloadWithinTheWindowIsTheUsersOwn() {
        let request = RefreshRequest(requestedAt: t0)
        XCTAssertTrue(RefreshState.isUserReload(request, at: t0.addingTimeInterval(2)))
        XCTAssertFalse(RefreshState.isUserReload(request, at: t0.addingTimeInterval(91)))
        XCTAssertFalse(RefreshState.isUserReload(nil, at: t0))
    }
}

final class UserReloadSchedulerTests: XCTestCase {
    let t0 = utc(2026, 9, 27, 12, 0, 0)
    let c0: UInt64 = 20_000_000_000_000_000

    func at(_ m: Double) -> SchedulerClock {
        SchedulerClock(wall: t0.addingTimeInterval(m * 60), continuous: UInt64(Int64(c0) + Int64(m * 60 * 1e9)), boot: "a")
    }

    func fingerprint(_ change: (inout SnapshotSketch) -> Void = { _ in }) -> DisplayFingerprint {
        var sketch = SnapshotSketch()
        change(&sketch)
        return DisplayFingerprint(sketch.build())
    }

    /// A press's reasons: what changed since the widget was last asked,
    /// and the press itself.
    func testAPressNamesItsChangesAndItself() {
        let state = ReloadState(lastRequest: at(0), requested: fingerprint(), requests: [at(0)])
        XCTAssertEqual(ReloadScheduler.pressReasons(state, current: fingerprint(), clock: at(1)), [.user])
        let moved = ReloadScheduler.pressReasons(state, current: fingerprint { $0.active = "2" }, clock: at(1))
        XCTAssertTrue(moved.contains(.active) && moved.contains(.user), "\(moved)")
    }

    /// Ordinary changes and urgent ones both wait ten minutes.
    func testOrdinaryChangesWaitTenMinutes() {
        XCTAssertEqual(ReloadScheduler.spacing, 10 * 60)
        let state = ReloadState(lastRequest: at(0), requested: fingerprint(), requests: [at(0)])
        let moved = fingerprint { $0.five = 25 }
        XCTAssertFalse(ReloadScheduler.decide(state, current: moved, clock: at(9.9)).decision.fire)
        XCTAssertTrue(ReloadScheduler.decide(state, current: moved, clock: at(10)).decision.fire)
    }
}

/// Presses are numbered; an answered press shows fresh numbers under the
/// plain footer.
final class RefreshPressTests: XCTestCase {
    let t0 = utc(2026, 9, 28, 16, 8, 0)
    let c0: UInt64 = 20_000_000_000_000_000

    func tempDir() throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: FileManager.default.temporaryDirectory, create: true)
    }

    func at(_ m: Double) -> SchedulerClock {
        SchedulerClock(wall: t0.addingTimeInterval(m * 60), continuous: UInt64(Int64(c0) + Int64(m * 60 * 1e9)), boot: "a")
    }

    func testEachPressGetsTheNextNumber() throws {
        let dir = try tempDir()
        XCTAssertEqual(try RefreshRequestStore.request(in: dir, at: t0).sequence, 1)
        XCTAssertEqual(try RefreshRequestStore.request(in: dir, at: t0.addingTimeInterval(-3600)).sequence, 2,
                       "numbered, whatever the clock says")
        try Data(#"{"requestedAt": 1790000000}"#.utf8).write(to: dir.appendingPathComponent(RefreshRequestStore.fileName))
        XCTAssertEqual(RefreshRequestStore.read(in: dir)?.sequence, 0, "a request from before numbering")
    }

    /// The intent waits for the agent's new snapshot, so the reload it
    /// triggers already shows fresh numbers.
    func testTheIntentWaitsForTheAgentsSnapshot() async throws {
        let dir = try tempDir()
        let request = try RefreshRequestStore.request(in: dir, at: Date())
        let snapshotURL = dir.appendingPathComponent(SharedContainer.snapshotFileName)
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            try? SnapshotStore.write(UsageSnapshot(writtenAt: request.requestedAt.addingTimeInterval(-600), providers: [],
                                                   writeSequence: request.afterSnapshot + 1),
                                     to: snapshotURL)
        }
        let started = Date()
        let answered = await RefreshRequestStore.waitForAnswer(in: dir, to: request, timeout: 5)
        XCTAssertEqual(answered, .answered)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        let later = try RefreshRequestStore.request(in: dir, at: Date())
        let quiet = await RefreshRequestStore.waitForAnswer(in: dir, to: later, timeout: 0.4)
        XCTAssertEqual(quiet, .timedOut, "no newer snapshot: gives up at the timeout")
    }

    /// Cancelled, the wait returns at once and reads nothing more.
    func testACancelledWaitStopsAtOnce() async throws {
        let dir = try tempDir()
        let request = try RefreshRequestStore.request(in: dir, at: Date())
        let reads = ReadCounter()
        let task = Task {
            await RefreshRequestStore.waitForAnswer(in: dir, to: request, timeout: 5, interval: 0.05,
                                                    read: { url in reads.add(); return SnapshotStore.read(from: url) })
        }
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        task.cancel()
        let atCancel = reads.count
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertLessThanOrEqual(reads.count, atCancel + 1, "no reads after the cancel landed")
    }

    /// A request numbered outside 0..<Int.max/2 reads as absent, and the
    /// next press starts a new session at 1; the last valid number wraps.
    func testOutOfRangeRequestNumbersStartANewSession() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent(RefreshRequestStore.fileName)
        for bad in [Int.max, Int.max / 2] {
            try Data(#"{"requestedAt": 1790000000, "sequence": \#(bad), "session": "S"}"#.utf8).write(to: url)
            XCTAssertNil(RefreshRequestStore.read(in: dir), "\(bad)")
            let next = try RefreshRequestStore.request(in: dir, at: t0)
            XCTAssertEqual(next.sequence, 1)
            XCTAssertNotEqual(next.session, "S")
        }
        try Data(#"{"requestedAt": 1790000000, "sequence": \#(Int.max / 2 - 1), "session": "S"}"#.utf8).write(to: url)
        let wrapped = try RefreshRequestStore.request(in: dir, at: t0)
        XCTAssertEqual(wrapped.sequence, 1, "the last valid number wraps")
        XCTAssertNotEqual(wrapped.session, "S")
    }

    /// The file an earlier build left (no session id) keeps an empty
    /// session forever unless the intent replaces it: the next press
    /// starts a new session at 1. This is the owner's file of Oct 1.
    func testAnEmptySessionIsReplacedWithANewOne() throws {
        let dir = try tempDir()
        let owners = #"{"requestedAt":1790885010.281976,"session":"","afterWriter":"CF3BFB22-E232-4046-9BD8-943A073B5EB0","sequence":30,"afterSnapshot":4068}"#
        try Data(owners.utf8).write(to: dir.appendingPathComponent(RefreshRequestStore.fileName))
        XCTAssertEqual(RefreshRequestStore.read(in: dir)?.session, "")
        let next = try RefreshRequestStore.request(in: dir, at: t0)
        XCTAssertFalse(next.session.isEmpty)
        XCTAssertEqual(next.sequence, 1)
        let after = try RefreshRequestStore.request(in: dir, at: t0)
        XCTAssertEqual(after.session, next.session, "then it goes on counting in the new session")
        XCTAssertEqual(after.sequence, 2)
    }

    /// A missing or damaged file starts a new session at number 1.
    func testANewFileStartsANewSession() throws {
        let dir = try tempDir()
        let first = try RefreshRequestStore.request(in: dir, at: t0)
        let second = try RefreshRequestStore.request(in: dir, at: t0)
        XCTAssertEqual(second.session, first.session)
        XCTAssertFalse(first.session.isEmpty)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(RefreshRequestStore.fileName))
        let fresh = try RefreshRequestStore.request(in: dir, at: t0)
        XCTAssertNotEqual(fresh.session, first.session)
        XCTAssertEqual(fresh.sequence, 1)
        try Data("{".utf8).write(to: dir.appendingPathComponent(RefreshRequestStore.fileName))
        let afterDamage = try RefreshRequestStore.request(in: dir, at: t0)
        XCTAssertNotEqual(afterDamage.session, fresh.session)
        XCTAssertEqual(afterDamage.sequence, 1)
    }

    /// "Refreshing…" until the agent answers the press, then the plain
    /// "as of" footer; nothing else, whatever the cap.
    func testTheFooterStates() {
        let request = RefreshRequest(requestedAt: t0, sequence: 4, session: "s2", afterSnapshot: 5)
        XCTAssertEqual(RefreshState.footer(request: request, snapshot: SnapshotMark(writer: "", sequence: 5),
                                           at: t0.addingTimeInterval(3)), .refreshing)
        XCTAssertEqual(RefreshState.footer(request: request, snapshot: SnapshotMark(writer: "", sequence: 6),
                                           at: t0.addingTimeInterval(3)), .none, "answered")
        XCTAssertEqual(RefreshState.footer(request: request, snapshot: SnapshotMark(writer: "", sequence: 5),
                                           at: t0.addingTimeInterval(91)), .none, "after the window")
    }

    /// A press answered at the cap: the widget shows the new snapshot's
    /// numbers under the plain footer.
    func testAnAnsweredPressShowsTheFreshNumbersAndAPlainFooter() {
        let request = RefreshRequest(requestedAt: t0, sequence: 4, afterSnapshot: 5)
        var snapshot = UsageSnapshot(writtenAt: t0.addingTimeInterval(1), providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                AccountUsage(id: "1", label: "a@example.com", active: true, fetchedAt: t0.addingTimeInterval(1), windows: [
                    UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 77),
                ]),
            ]),
        ])
        snapshot.writeSequence = 6
        let content = WidgetContent.make(snapshot: snapshot, at: t0.addingTimeInterval(2), refresh: request)
        XCTAssertEqual(content.refreshFooter, .none)
        XCTAssertEqual(content.sections[0].accounts[0].rows[0].percentText, "77%")
    }

    /// A press re-measures every account (`cswap list --json --fresh`), so
    /// every account in its answer was measured within seconds of the
    /// press. The footer keeps its rule, the oldest current measurement on
    /// screen, and so shows the press's own minute: nothing between the
    /// snapshot and the "as of" text rounds it back or holds an older time.
    func testAFreshPressDatesTheFooterAtThePress() throws {
        let pressedAt = utc(2026, 10, 9, 16, 8, 10)
        let measured = [utc(2026, 10, 9, 16, 8, 13), utc(2026, 10, 9, 16, 8, 19), utc(2026, 10, 9, 16, 8, 51)]
        let rows = ["16:08:13", "16:08:19", "16:08:51"].enumerated().map { i, time in
            """
            {"number": \(i + 1), "email": "user\(i + 1)@example.com", "active": \(i == 0), "usageStatus": "ok",
             "usage": {"fiveHour": {"pct": 20.0, "resetsAt": "2026-10-09T20:00:00+00:00"},
                       "sevenDay": {"pct": 50.0, "resetsAt": "2026-10-14T00:00:00+00:00"}},
             "usageFetchedAt": "2026-10-09T\(time)Z"}
            """
        }
        let list = Data("{\"schemaVersion\": 1, \"accounts\": [\(rows.joined(separator: ","))]}".utf8)
        let accounts = try CswapListMapper.accounts(from: list)
        XCTAssertEqual(accounts.compactMap(\.fetchedAt), measured)
        XCTAssertTrue(measured.allSatisfy { abs($0.timeIntervalSince(pressedAt)) < 60 }, "all within 60 s of the press")

        let request = RefreshRequest(requestedAt: pressedAt, sequence: 4, session: "s", afterSnapshot: 5, afterWriter: "w")
        var snapshot = SnapshotBuilder.updating(nil, provider: CswapListMapper.provider, source: CswapListMapper.source,
                                                outcome: .success(accounts), now: utc(2026, 10, 9, 16, 8, 54))
        snapshot.writeSequence = 6
        snapshot.writerId = "w"
        let entries = WidgetContent.timelineEntries(for: snapshot, readAt: utc(2026, 10, 9, 16, 8, 55), refresh: request)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.content.refreshFooter, .none, "the press is answered")
        let shown = entry.content.sections.flatMap(\.accounts)
        XCTAssertEqual(shown.count, 3)
        let footer = try XCTUnwrap(entry.content.footerTime(for: shown))
        XCTAssertEqual(footer, utc(2026, 10, 9, 16, 8, 13), "the oldest fresh measurement, as measured")
        XCTAssertEqual(TimeText.asOf(footer, relativeTo: entry.date, locale: Locale(identifier: "en_US_POSIX"),
                                     timeZone: TimeZone(identifier: "UTC")!, calendar: Calendar(identifier: .gregorian)),
                       "as of 4:08\u{202F}PM", "the press's own minute")
    }

    /// No shipped source says anything about a refresh limit.
    func testNothingMentionsARefreshLimit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["App", "Widget", "Packages/UsageKit/Sources"] {
            let files = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(files.isEmpty, folder)
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8).lowercased()
                XCTAssertFalse(text.contains("limit reached"), file.lastPathComponent)
                XCTAssertFalse(text.contains("refreshresult"), file.lastPathComponent)
            }
        }
    }
}

final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
