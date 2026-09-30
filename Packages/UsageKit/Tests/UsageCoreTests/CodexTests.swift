import XCTest
@testable import UsageCore

final class CodexRolloutTests: XCTestCase {
    func testTheLastEventWithRateLimitsWinsAndNullsAndBadLinesAreSkipped() throws {
        let reading = try XCTUnwrap(CodexRolloutParser.lastReading(in: fixture("codex-rollout-weekly", ext: "jsonl"), now: utc(2026, 1, 16)))
        XCTAssertEqual(reading.source, .rollout)
        XCTAssertEqual(reading.measuredAt, ISODate.parse("2026-01-15T13:58:00.000Z"),
                       "the last event with rate limits; the later one with null rate limits is skipped")
        XCTAssertEqual(reading.planType, "pro")
        XCTAssertEqual(reading.limitId, "codex")
        XCTAssertNil(reading.resetCreditsAvailable, "rollouts never carry the reset count")
        XCTAssertEqual(reading.windows, [
            UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 40,
                        resetsAt: Date(timeIntervalSince1970: 1_768_996_800)),
        ], "the Pro plan's weekly window arrives as primary with no secondary")
    }

    func testAFiveHourAndAWeeklyWindowAreClassifiedByLength() throws {
        let reading = try XCTUnwrap(CodexRolloutParser.lastReading(in: fixture("codex-rollout-5h-weekly", ext: "jsonl"), now: utc(2026, 1, 16)))
        XCTAssertEqual(reading.windows.map(\.name), ["5h", "Weekly"])
        XCTAssertEqual(reading.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(reading.windows.map(\.usedPct), [60, 20])
        XCTAssertEqual(reading.planType, "plus")
    }

    func testPositionNeverDecidesTheKind() throws {
        let line = """
        {"timestamp":"2026-01-15T13:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":\
        {"plan_type":"plus","primary":{"used_percent":70,"window_minutes":10080,"resets_at":1768852800},\
        "secondary":{"used_percent":12,"window_minutes":300,"resets_at":1768485600}}}}
        """
        let reading = try XCTUnwrap(CodexRolloutParser.lastReading(in: Data(line.utf8), now: utc(2026, 1, 16)))
        XCTAssertEqual(reading.windows.map(\.name), ["5h", "Weekly"], "shortest first, whatever the position")
        XCTAssertEqual(reading.windows.map(\.usedPct), [12, 70])
    }

    func testNothingUsableGivesNoReading() {
        for text in ["", "garbage\\n{", #"{"timestamp":"2026-09-27T13:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#,
                     #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5,"window_minutes":300}}}}"#] {
            XCTAssertNil(CodexRolloutParser.lastReading(in: Data(text.utf8), now: utc(2026, 9, 28)), text)
        }
    }
}

final class CodexClassifierTests: XCTestCase {
    func kind(_ minutes: Int) -> (UsageWindow.Kind, String)? {
        CodexWindowClassifier.window(usedPercent: 10, windowMinutes: minutes, resetsAtEpoch: nil).map { ($0.kind, $0.name) }
    }

    func testBoundaries() {
        XCTAssertEqual(kind(300)?.0, .session); XCTAssertEqual(kind(300)?.1, "5h")
        XCTAssertEqual(kind(360)?.0, .session); XCTAssertEqual(kind(360)?.1, "6h")
        XCTAssertEqual(kind(1440)?.0, .weekly); XCTAssertEqual(kind(1440)?.1, "Weekly")
        XCTAssertEqual(kind(10_080)?.0, .weekly); XCTAssertEqual(kind(10_080)?.1, "Weekly")
        XCTAssertEqual(kind(720)?.0, .session, "between six hours and a day counts as a session")
        XCTAssertEqual(kind(720)?.1, "12h")
        XCTAssertEqual(kind(1439)?.0, .session)
    }

    func testValuesAreCleanedLikeCswapsPercents() {
        XCTAssertNil(CodexWindowClassifier.window(usedPercent: 1e20, windowMinutes: 300, resetsAtEpoch: nil)?.usedPct)
        XCTAssertEqual(CodexWindowClassifier.window(usedPercent: -3, windowMinutes: 300, resetsAtEpoch: nil)?.usedPct, 0)
        XCTAssertNil(CodexWindowClassifier.window(usedPercent: 10, windowMinutes: 300, resetsAtEpoch: Double.nan)?.resetsAt)
        XCTAssertEqual(CodexWindowClassifier.window(usedPercent: 10, windowMinutes: 300, resetsAtEpoch: 1_768_485_600)?.resetsAt,
                       Date(timeIntervalSince1970: 1_768_485_600))
        XCTAssertNil(CodexWindowClassifier.window(usedPercent: 10, windowMinutes: nil, resetsAtEpoch: nil),
                     "a window of unknown length cannot be classified")
    }
}

final class CodexAppServerParserTests: XCTestCase {
    func result(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    }

    func testTheRateLimitsReplyIsRead() throws {
        let fetched = utc(2026, 1, 15, 14, 5, 0)
        let reading = try XCTUnwrap(CodexAppServerParser.reading(fromResult: result("codex-app-server-result"), fetchedAt: fetched))
        XCTAssertEqual(reading.source, .appServer)
        XCTAssertEqual(reading.measuredAt, fetched)
        XCTAssertEqual(reading.planType, "pro")
        XCTAssertEqual(reading.resetCreditsAvailable, 2)
        XCTAssertEqual(reading.windows, [
            UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 45,
                        resetsAt: Date(timeIntervalSince1970: 1_768_996_800)),
        ])
    }

    func testAMissingResetSummaryIsUnknown() throws {
        var body = try result("codex-app-server-result")
        body["rateLimitResetCredits"] = NSNull()
        XCTAssertNil(CodexAppServerParser.reading(fromResult: body, fetchedAt: utc(2026, 9, 27))?.resetCreditsAvailable)
    }

    func testAReplyWithoutRateLimitsIsNoReading() {
        XCTAssertNil(CodexAppServerParser.reading(fromResult: ["rateLimitResetCredits": ["availableCount": 1]], fetchedAt: utc(2026, 9, 27)))
    }
}

final class CodexMergeTests: XCTestCase {
    let now = utc(2026, 9, 27, 14, 10, 0)

    func weekly(_ pct: Double) -> [UsageWindow] {
        [UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: pct,
                     resetsAt: utc(2026, 10, 3))]
    }

    func rollout(at date: Date, pct: Double = 35) -> CodexReading {
        CodexReading(source: .rollout, measuredAt: date, windows: weekly(pct), planType: "pro", limitId: "codex")
    }

    func appServer(at date: Date, pct: Double = 41, resets: Int? = 2) -> CodexReading {
        CodexReading(source: .appServer, measuredAt: date, windows: weekly(pct), planType: "pro",
                     resetCreditsAvailable: resets)
    }

    func testANewerRolloutGivesTheWindowsAndTheAppServerTheResetCount() throws {
        let block = CodexMerge.block(rollout: rollout(at: utc(2026, 9, 27, 14, 5, 0)),
                                     appServer: appServer(at: utc(2026, 9, 27, 13, 55, 0)),
                                     appServerError: nil, codexFound: true, now: now)
        XCTAssertEqual(block.provider, "codex")
        XCTAssertEqual(block.source, "rollout")
        XCTAssertEqual(block.status, .ok)
        XCTAssertNil(block.error)
        let account = try block.accounts[at: 0]
        XCTAssertEqual(account.id, "codex")
        XCTAssertEqual(account.label, "Codex")
        XCTAssertFalse(account.active)
        XCTAssertEqual(account.status, .ok)
        XCTAssertEqual(account.fetchedAt, utc(2026, 9, 27, 14, 5, 0))
        XCTAssertEqual(account.windows.map(\.usedPct), [35])
        XCTAssertEqual(block.extras, ["resetCreditsAvailable": .number(2), "planType": .string("pro"), "appServerCheckedAt": .null])
    }

    func testANewerAppServerReadingGivesTheWindows() throws {
        let block = CodexMerge.block(rollout: rollout(at: utc(2026, 9, 27, 13, 0, 0)),
                                     appServer: appServer(at: utc(2026, 9, 27, 14, 5, 0)),
                                     appServerError: nil, codexFound: true, now: now)
        XCTAssertEqual(block.source, "app-server")
        XCTAssertEqual(try block.accounts[at: 0].windows.map(\.usedPct), [41])
        XCTAssertEqual(try block.accounts[at: 0].fetchedAt, utc(2026, 9, 27, 14, 5, 0))
    }

    /// Codex's line is four hours: it is asked every three when idle.
    func testANewestReadingOlderThanFourHoursIsStale() throws {
        let block = CodexMerge.block(rollout: rollout(at: utc(2026, 9, 27, 10, 9, 0)), appServer: nil,
                                     appServerError: nil, codexFound: true, now: now)
        XCTAssertEqual(try block.accounts[at: 0].status, .stale)
        XCTAssertEqual(try block.accounts[at: 0].statusNote, "No new reading")
        let fresh = CodexMerge.block(rollout: rollout(at: utc(2026, 9, 27, 10, 11, 0)), appServer: nil,
                                     appServerError: nil, codexFound: true, now: now)
        XCTAssertEqual(try fresh.accounts[at: 0].status, .ok, "just under four hours")
    }

    func testNoBinaryAndNoRolloutsIsUnavailable() throws {
        let block = CodexMerge.block(rollout: nil, appServer: nil, appServerError: nil, codexFound: false, now: now)
        XCTAssertEqual(block.status, .ok)
        XCTAssertEqual(try block.accounts[at: 0].status, .unavailable)
        XCTAssertEqual(try block.accounts[at: 0].statusNote, "Codex not found")
        XCTAssertEqual(try block.accounts[at: 0].windows, [])
        XCTAssertEqual(block.extras, ["resetCreditsAvailable": .null, "planType": .null, "appServerCheckedAt": .null])
    }

    /// A failed app-server call is the collector's problem, not a change in
    /// usage: while a fresh reading exists the block stays ok and the reason
    /// goes to `collectorError`, which the widget does not draw.
    func testAnAppServerFailureWithAFreshReadingIsNotAUsageStatus() throws {
        let block = CodexMerge.block(rollout: rollout(at: utc(2026, 9, 27, 14, 5, 0)), appServer: nil,
                                     appServerError: "codex app-server did not answer within 20 s for sam@example.com",
                                     codexFound: true, now: now)
        XCTAssertEqual(block.status, .ok)
        XCTAssertNil(block.error)
        XCTAssertEqual(block.collectorError, "codex app-server did not answer within 20 s for sam***@***.com")
        XCTAssertEqual(try block.accounts[at: 0].status, .ok)
        XCTAssertEqual(try block.accounts[at: 0].windows.map(\.usedPct), [35], "the rollout data still shows")
        XCTAssertEqual(block.extras["resetCreditsAvailable"], .null)
    }

    func testWithoutAFreshReadingTheFailureBecomesTheStatus() throws {
        let block = CodexMerge.block(rollout: rollout(at: utc(2026, 9, 27, 10, 0, 0)), appServer: nil,
                                     appServerError: "codex app-server did not answer within 20 s",
                                     codexFound: true, now: now)
        XCTAssertEqual(block.status, .error)
        XCTAssertEqual(block.error, "codex app-server did not answer within 20 s")
        XCTAssertEqual(block.collectorError, "codex app-server did not answer within 20 s")
        XCTAssertEqual(try block.accounts[at: 0].status, .stale)
    }

    func testNoReadingAtAllWithAFailureIsAnError() throws {
        let block = CodexMerge.block(rollout: nil, appServer: nil, appServerError: "codex not found",
                                     codexFound: false, now: now)
        XCTAssertEqual(block.status, .error)
        XCTAssertEqual(try block.accounts[at: 0].status, .unavailable)
    }

    func testAStaleReadingWithoutAFailureKeepsTheBlockOk() throws {
        let block = CodexMerge.block(rollout: rollout(at: utc(2026, 9, 27, 10, 0, 0)), appServer: nil,
                                     appServerError: nil, codexFound: true, now: now)
        XCTAssertEqual(block.status, .ok)
        XCTAssertNil(block.collectorError)
        XCTAssertEqual(try block.accounts[at: 0].status, .stale)
    }

    func testATieGoesToTheAppServer() throws {
        let at = utc(2026, 9, 27, 14, 5, 0)
        let block = CodexMerge.block(rollout: rollout(at: at), appServer: appServer(at: at),
                                     appServerError: nil, codexFound: true, now: now)
        XCTAssertEqual(block.source, "app-server")
        XCTAssertEqual(try block.accounts[at: 0].windows.map(\.usedPct), [41])
    }

    /// The last known reading (seeded from the snapshot after a restart)
    /// shows until something newer arrives, with its reset count.
    func testTheLastKnownReadingFillsIn() throws {
        let known = appServer(at: utc(2026, 9, 27, 13, 50, 0), pct: 60, resets: 2)
        let alone = CodexMerge.block(rollout: nil, appServer: nil, lastKnown: known,
                                     appServerError: "offline", codexFound: true, now: now)
        XCTAssertEqual(alone.status, .ok, "twenty minutes old is still fresh")
        XCTAssertEqual(try alone.accounts[at: 0].windows.map(\.usedPct), [60])
        XCTAssertEqual(try alone.accounts[at: 0].fetchedAt, utc(2026, 9, 27, 13, 50, 0))
        XCTAssertEqual(alone.extras["resetCreditsAvailable"], .number(2))

        let newer = CodexMerge.block(rollout: rollout(at: utc(2026, 9, 27, 14, 5, 0)), appServer: nil, lastKnown: known,
                                     appServerError: nil, codexFound: true, now: now)
        XCTAssertEqual(try newer.accounts[at: 0].windows.map(\.usedPct), [35])
        XCTAssertEqual(newer.extras["resetCreditsAvailable"], .number(2), "the count still comes from an app-server answer")

        let answered = CodexMerge.block(rollout: nil, appServer: appServer(at: utc(2026, 9, 27, 13, 40, 0), resets: 3),
                                        lastKnown: known, appServerError: nil, codexFound: true, now: now)
        XCTAssertEqual(answered.extras["resetCreditsAvailable"], .number(3), "a live answer's count wins")
        XCTAssertEqual(try answered.accounts[at: 0].windows.map(\.usedPct), [60], "but the newer windows stay")
    }

    func testTheCollectorErrorIsStoredButNeverReloads() throws {
        var block = CodexMerge.block(rollout: rollout(at: utc(2026, 9, 27, 14, 5, 0)), appServer: nil,
                                     appServerError: nil, codexFound: true, now: now)
        let quiet = UsageSnapshot(writtenAt: now, providers: [block])
        block.collectorError = "codex app-server did not answer within 20 s"
        let noisy = UsageSnapshot(writtenAt: now, providers: [block])
        XCTAssertEqual(ReloadGate.reasons(from: quiet, to: noisy, now: now), [])
        XCTAssertNil(WidgetContent.make(snapshot: noisy, at: now).sections[0].errorText, "the widget does not draw it")
        let decoded = try SnapshotStore.decode(SnapshotStore.encode(noisy))
        XCTAssertEqual(decoded.providers[0].collectorError, "codex app-server did not answer within 20 s")
        block.collectorError = "failed for sam@example.com"
        let redacted = SnapshotValidator.sanitized(UsageSnapshot(writtenAt: now, providers: [block]))
        XCTAssertEqual(redacted.providers[0].collectorError, "failed for sam***@***.com")
    }

    func testAPassedResetRollsToZeroLikeTheClaudeWindows() throws {
        var reading = rollout(at: utc(2026, 9, 27, 14, 5, 0))
        reading.windows[0].resetsAt = utc(2026, 9, 27, 14, 7, 0)
        let block = CodexMerge.block(rollout: reading, appServer: nil, appServerError: nil, codexFound: true, now: now)
        let snapshot = UsageSnapshot(writtenAt: now, providers: [block])
        let row = try WidgetContent.make(snapshot: snapshot, at: now).sections[at: 0].accounts[at: 0].rows[at: 0]
        XCTAssertEqual(row.percentText, "0%")
        XCTAssertEqual(row.resetsAt, utc(2026, 10, 4, 14, 7, 0), "rolled a week forward")
    }
}
