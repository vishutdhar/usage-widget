import XCTest
@testable import UsageCore

/// Codex readings refresh every three hours when Codex is idle, so Codex
/// goes stale at four hours; cswap refreshes every few minutes, so Claude
/// stays at two. One place holds both lines.
final class ProviderStalenessTests: XCTestCase {
    let t0 = utc(2026, 9, 27, 12, 0, 0)

    func testEachProviderHasItsLine() {
        XCTAssertEqual(Staleness.line(for: "codex"), 4 * 3600)
        XCTAssertEqual(Staleness.line(for: "claude"), 2 * 3600)
        XCTAssertEqual(Staleness.line(for: "anything else"), 2 * 3600)
        XCTAssertEqual(CodexMerge.staleAfter, Staleness.line(for: CodexMerge.provider))
    }

    func snapshot(codexAt: Date, claudeAt: Date) -> UsageSnapshot {
        let weekly = [UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 40)]
        return UsageSnapshot(writtenAt: t0, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                AccountUsage(id: "1", label: "a@example.com", active: true, fetchedAt: claudeAt, windows: weekly),
            ]),
            ProviderUsage(provider: "codex", source: "app-server", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: codexAt, windows: weekly),
            ]),
        ])
    }

    func testTheWidgetDimsCodexAtFourHours() {
        let three = WidgetContent.make(snapshot: snapshot(codexAt: t0, claudeAt: t0), at: t0.addingTimeInterval(3 * 3600))
        XCTAssertTrue(three.sections[0].accounts[0].dimmed, "Claude at three hours")
        XCTAssertFalse(three.sections[1].accounts[0].dimmed, "Codex at three hours")
        let five = WidgetContent.make(snapshot: snapshot(codexAt: t0, claudeAt: t0), at: t0.addingTimeInterval(5 * 3600))
        XCTAssertTrue(five.sections[1].accounts[0].dimmed)
    }

    func testTheAgingReloadFollowsEachProvidersLine() {
        let old = snapshot(codexAt: t0, claudeAt: t0.addingTimeInterval(-3600))
        var new = old
        new.providers[1].accounts[0].fetchedAt = t0.addingTimeInterval(600)
        XCTAssertEqual(ReloadGate.reasons(from: old, to: new, now: t0.addingTimeInterval(2 * 3600 - 30)), [],
                       "Codex shown two hours ago is not about to dim")
        XCTAssertEqual(ReloadGate.reasons(from: old, to: new, now: t0.addingTimeInterval(4 * 3600 - 30)), [.aging])
    }

    func testTheTimelinePlansCodexDimmingAtFourHours() {
        let now = t0
        let plan = TimelinePlan.plan(for: snapshot(codexAt: now.addingTimeInterval(-3600), claudeAt: now), now: now)
        XCTAssertTrue(plan.entries.contains(TimelinePlan.bucketEnd(now.addingTimeInterval(3 * 3600 + 1))), "\(plan.entries)")
        XCTAssertFalse(plan.entries.contains(TimelinePlan.bucketEnd(now.addingTimeInterval(3600 + 1))))
        XCTAssertTrue(plan.entries.contains(TimelinePlan.bucketEnd(now.addingTimeInterval(2 * 3600 + 1))), "Claude still at two hours")
    }

    func testCodexIsStaleOnlyAfterFourHours() throws {
        let reading = CodexReading(source: .appServer, measuredAt: t0, windows: [
            UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 40),
        ])
        let three = CodexMerge.block(rollout: nil, appServer: reading, appServerError: nil, codexFound: true,
                                     now: t0.addingTimeInterval(3 * 3600 + 59 * 60))
        XCTAssertEqual(three.accounts[0].status, .ok)
        let four = CodexMerge.block(rollout: nil, appServer: reading, appServerError: nil, codexFound: true,
                                    now: t0.addingTimeInterval(4 * 3600 + 60))
        XCTAssertEqual(four.accounts[0].status, .stale)
    }
}

final class AppServerCheckedAtTests: XCTestCase {
    func testTheBlockCarriesTheLastAnswerTime() {
        let now = utc(2026, 9, 27, 14, 0, 0)
        let answered = utc(2026, 9, 27, 12, 30, 0)
        let block = CodexMerge.block(rollout: nil, appServer: nil, appServerCheckedAt: answered, appServerError: nil,
                                     codexFound: true, now: now)
        XCTAssertEqual(block.extras["appServerCheckedAt"], .string(ISODate.format(answered)))
        let none = CodexMerge.block(rollout: nil, appServer: nil, appServerError: nil, codexFound: true, now: now)
        XCTAssertEqual(none.extras["appServerCheckedAt"], .null)
    }
}

/// A rollout event dated more than two minutes ahead of now is invalid:
/// skipped like an empty one, so the file can still give an earlier event.
final class FutureEventTests: XCTestCase {
    let now = utc(2026, 9, 27, 14, 0, 0)

    func line(_ stamp: String, _ pct: Int) -> String {
        #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(pct),"window_minutes":10080,"resets_at":1791072000},"secondary":null}}}"#
    }

    func read(_ lines: [String]) -> CodexReading? {
        CodexRolloutParser.lastReading(in: Data((lines.joined(separator: "\n") + "\n").utf8), now: now)
    }

    func testAFutureDatedLastEventFallsBackToAnEarlierOne() throws {
        let reading = try XCTUnwrap(read([line("2026-09-27T13:00:00.000Z", 35), line("2026-09-27T14:10:00.000Z", 90)]))
        XCTAssertEqual(reading.windows.map(\.usedPct), [35])
        XCTAssertEqual(reading.measuredAt, utc(2026, 9, 27, 13, 0, 0))
    }

    func testTwoMinutesAheadIsTheLine() throws {
        XCTAssertEqual(read([line("2026-09-27T14:02:00.000Z", 40)])?.measuredAt, utc(2026, 9, 27, 14, 2, 0),
                       "exactly two minutes ahead is still valid")
        XCTAssertNil(read([line("2026-09-27T14:02:01.000Z", 40)]))
    }

    func testAnAllFutureTailGivesNothing() {
        XCTAssertNil(read([line("2026-09-27T18:00:00.000Z", 80), line("2026-09-27T19:00:00.000Z", 81)]))
    }
}

/// A reading without a usable window is no reading at all.
final class EmptyLimitsTests: XCTestCase {
    func line(_ stamp: String, _ limits: String) -> String {
        #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":\#(limits)}}"#
    }

    func testAnEmptyRolloutEventIsSkippedForAnEarlierOne() throws {
        let text = [
            line("2026-09-27T13:00:00.000Z", #"{"primary":{"used_percent":35,"window_minutes":10080,"resets_at":1791072000},"secondary":null}"#),
            line("2026-09-27T14:00:00.000Z", "{}"),
            line("2026-09-27T14:05:00.000Z", #"{"primary":null,"secondary":null}"#),
        ].joined(separator: "\n") + "\n"
        let reading = try XCTUnwrap(CodexRolloutParser.lastReading(in: Data(text.utf8), now: utc(2026, 9, 28)))
        XCTAssertEqual(reading.measuredAt, ISODate.parse("2026-09-27T13:00:00Z"))
        XCTAssertEqual(reading.windows.map(\.usedPct), [35])
        XCTAssertNil(CodexRolloutParser.lastReading(in: Data((line("2026-09-27T14:00:00.000Z", "{}") + "\n").utf8), now: utc(2026, 9, 28)))
    }

    func testAnAppServerReplyWithoutLimitsIsNotAReading() {
        let now = utc(2026, 9, 27, 14, 0, 0)
        XCTAssertNil(CodexAppServerParser.reading(fromResult: ["rateLimits": [String: Any]()], fetchedAt: now))
        XCTAssertNil(CodexAppServerParser.reading(fromResult: ["rateLimits": ["primary": NSNull(), "secondary": NSNull()],
                                                               "rateLimitResetCredits": ["availableCount": 2]], fetchedAt: now))
    }
}

/// A hidden provider block (Show Codex off) stays in the snapshot so a
/// restart can seed from it, but draws and reloads as if absent.
final class HiddenProviderTests: XCTestCase {
    let now = utc(2026, 9, 28, 16, 0, 0)

    func snapshot(hidden: Bool) -> UsageSnapshot {
        var codex = ProviderUsage(provider: "codex", source: "app-server", status: .ok, accounts: [
            AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: now.addingTimeInterval(-3600), windows: [
                UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 40,
                            resetsAt: now.addingTimeInterval(1800)),
            ]),
        ])
        codex.hidden = hidden
        return UsageSnapshot(writtenAt: now, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                AccountUsage(id: "1", label: "a@example.com", active: true, fetchedAt: now, windows: []),
            ]),
            codex,
        ])
    }

    func testTheWidgetLeavesAHiddenBlockOut() {
        XCTAssertEqual(WidgetContent.make(snapshot: snapshot(hidden: true), at: now).sections.map(\.provider), ["claude"])
        XCTAssertEqual(WidgetContent.make(snapshot: snapshot(hidden: false), at: now).sections.map(\.provider), ["claude", "codex"])
    }

    func testTheFingerprintAndTimelineTreatItAsAbsent() {
        XCTAssertEqual(DisplayFingerprint(snapshot(hidden: true)).providerOrder, ["claude"])
        XCTAssertEqual(ReloadGate.reasons(from: snapshot(hidden: false), to: snapshot(hidden: true), now: now), [.layout])
        let plan = TimelinePlan.plan(for: snapshot(hidden: true), now: now)
        XCTAssertFalse(plan.entries.contains(TimelinePlan.bucketEnd(now.addingTimeInterval(1800))), "its reset is not planned")
    }

    func testHiddenRoundTripsAndDefaultsToShown() throws {
        let decoded = try SnapshotStore.decode(SnapshotStore.encode(snapshot(hidden: true)))
        XCTAssertTrue(decoded.providers[1].hidden)
        XCTAssertFalse(decoded.providers[0].hidden)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: SnapshotStore.encode(snapshot(hidden: true))) as? [String: Any])
        var providers = try XCTUnwrap(object["providers"] as? [[String: Any]])
        providers[1].removeValue(forKey: "hidden")
        object["providers"] = providers
        let old = try SnapshotStore.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(old.providers[1].hidden, "a snapshot from before the flag shows its blocks")
    }
}
