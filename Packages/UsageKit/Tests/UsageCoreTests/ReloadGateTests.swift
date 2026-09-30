import XCTest
@testable import UsageCore

/// Builds snapshots that differ in one visible detail at a time.
struct SnapshotSketch {
    var t0 = utc(2026, 9, 27, 12, 0, 0)
    var active = "1"
    var five: Double? = 20.1
    var seven: Double = 80
    var providerStatus: ProviderUsage.Status = .ok
    var providerError: String?
    var accountStatus: AccountUsage.Status = .ok
    var secondAccount = true
    var writtenAt: Date?
    var fiveReset: Date?
    var sevenReset: Date?
    var sevenExpected: Double?
    var extraWindow = false
    var statusNote: String?
    var spendAmount: Double?
    var fetchedAt: Date?

    func build() -> UsageSnapshot {
        var windows = [
            UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: five, resetsAt: fiveReset),
            UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: seven, resetsAt: sevenReset,
                        expectedPct: sevenExpected),
        ]
        if extraWindow {
            windows.append(UsageWindow(kind: .model, name: "Fable", windowSeconds: 604_800, usedPct: 10))
        }
        if let spendAmount {
            windows.append(UsageWindow(kind: .spend, name: "Spend", windowSeconds: 0, usedPct: 40,
                                       amount: spendAmount, limit: 100, currency: "USD"))
        }
        var accounts = [
            AccountUsage(id: "1", label: "alex@example.com", active: active == "1", fetchedAt: fetchedAt ?? t0,
                         windows: windows, status: accountStatus, statusNote: statusNote),
        ]
        if secondAccount {
            accounts.append(AccountUsage(id: "2", label: "sam@example.com", active: active == "2", fetchedAt: t0, windows: [
                UsageWindow(kind: .session, name: "5h", windowSeconds: 18_000, usedPct: 0),
                UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 90),
            ]))
        }
        return UsageSnapshot(writtenAt: writtenAt ?? t0, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: providerStatus, error: providerError,
                          accounts: accounts),
        ])
    }
}

final class ReloadGateTests: XCTestCase {
    let now = utc(2026, 9, 27, 12, 0, 0)

    func reasons(_ change: (inout SnapshotSketch) -> Void, from base: (inout SnapshotSketch) -> Void = { _ in }) -> [ReloadReason] {
        var old = SnapshotSketch()
        base(&old)
        var new = old
        change(&new)
        return ReloadGate.reasons(from: old.build(), to: new.build(), now: now)
    }

    func testFirstSnapshot() {
        XCTAssertEqual(ReloadGate.reasons(from: nil, to: SnapshotSketch().build(), now: now), [.first])
    }

    func testNothingVisibleChanged() {
        XCTAssertEqual(reasons { _ in }, [])
        XCTAssertEqual(reasons { $0.writtenAt = self.now.addingTimeInterval(60) }, [], "a rewrite alone is invisible")
        XCTAssertEqual(reasons { $0.five = 20.4 }, [], "20.1 and 20.4 both read 20%")
        XCTAssertEqual(reasons({ $0.five = 20.4 }, from: { $0.five = 20.5 }), [], "20.5 and 20.4 both read 20%")
    }

    /// The provider's error line is shown in the widget: a new reason for
    /// a failure, a different one, or the reload state error set on a
    /// healthy provider is an ordinary change.
    func testAChangedErrorLineIsOrdinary() {
        XCTAssertEqual(reasons { $0.providerError = "cswap not found" }, [.errorText])
        XCTAssertEqual(reasons({ $0.providerError = "cswap timed out" }, from: { $0.providerError = "cswap not found" }),
                       [.errorText])
        XCTAssertEqual(reasons({ $0.providerError = "cswap not found" }, from: { $0.providerError = "cswap not found" }), [])
        XCTAssertFalse(ReloadReason.errorText.isUrgent)
        XCTAssertEqual(reasons({ $0.providerError = nil }, from: { $0.providerStatus = .error; $0.providerError = "x" }),
                       [.errorText], "a failed provider without a reason shows Unknown error")
        XCTAssertEqual(reasons({ $0.providerError = "Unknown error" }, from: { $0.providerStatus = .error }), [],
                       "the line the widget shows is the same")
    }

    /// A fingerprint saved before the error line was recorded reads as none.
    func testAnOlderFingerprintReadsWithoutAnErrorLine() throws {
        let current = DisplayFingerprint(SnapshotSketch().build())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        var providers = try XCTUnwrap(object["providers"] as? [String: Any])
        var claude = try XCTUnwrap(providers["claude"] as? [String: Any])
        claude.removeValue(forKey: "error")
        providers["claude"] = claude
        object["providers"] = providers
        let old = try JSONDecoder().decode(DisplayFingerprint.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(ReloadGate.reasons(from: old, to: current, now: now), [])
    }

    func testPercentIsOrdinary() {
        XCTAssertEqual(reasons { $0.five = 20.6 }, [.percent])
        XCTAssertFalse(ReloadReason.percent.isUrgent)
    }

    func testBandCrossingsAreUrgent() {
        XCTAssertEqual(reasons({ $0.seven = 70 }, from: { $0.seven = 69 }), [.band, .percent], "into yellow")
        XCTAssertEqual(reasons({ $0.seven = 90 }, from: { $0.seven = 89 }), [.band, .percent], "into red")
        XCTAssertEqual(reasons({ $0.seven = 100 }, from: { $0.seven = 99 }), [.band, .percent], "the (!) marker")
        XCTAssertEqual(reasons({ $0.five = nil }), [.band, .percent], "a value becoming unknown")
        XCTAssertEqual(reasons({ $0.seven = 75 }, from: { $0.seven = 72 }), [.percent], "inside one band")
        XCTAssertTrue(ReloadReason.band.isUrgent)
    }

    func testStatusActiveAndLayoutAreUrgent() {
        XCTAssertEqual(reasons { $0.providerStatus = .error }, [.status, .errorText], "and its error line appears")
        XCTAssertEqual(reasons { $0.accountStatus = .stale }, [.status])
        XCTAssertEqual(reasons { $0.active = "2" }, [.active])
        XCTAssertEqual(reasons { $0.secondAccount = false }, [.layout])
        XCTAssertEqual(reasons { $0.extraWindow = true }, [.layout])
        XCTAssertTrue(ReloadReason.status.isUrgent)
        XCTAssertTrue(ReloadReason.active.isUrgent)
        XCTAssertTrue(ReloadReason.layout.isUrgent)
        XCTAssertTrue(ReloadReason.first.isUrgent)
    }

    func testSpendAmountTextIsOrdinary() {
        XCTAssertEqual(reasons({ $0.spendAmount = 41 }, from: { $0.spendAmount = 40 }), [.spend],
                       "$40 of $100 to $41 of $100, with the percent unchanged")
        XCTAssertFalse(ReloadReason.spend.isUrgent)
    }

    func testStatusNoteChangeIsUrgent() {
        XCTAssertEqual(reasons({ $0.statusNote = "Keychain locked" }, from: { $0.accountStatus = .stale; $0.statusNote = "Token expired" }),
                       [.status], "same status, a different thing to do about it")
    }

    func testShownNumbersAboutToDimWithNewerDataIsOrdinary() {
        let shown = now.addingTimeInterval(-2 * 3600 + 30)
        XCTAssertEqual(reasons({ $0.fetchedAt = self.now }, from: { $0.fetchedAt = shown }), [.aging],
                       "the widget's numbers dim within the next poll and fresher ones exist")
        XCTAssertFalse(ReloadReason.aging.isUrgent)
    }

    /// A requested fingerprint without a measurement time (an older build's)
    /// makes the shown time unknown: fresher numbers are an aging reason.
    func testAnUnknownShownMeasurementWithFreshNumbersIsAging() {
        var shown = DisplayFingerprint(SnapshotSketch().build())
        shown.providers["claude"]?.accounts["1"]?.fetchedAt = nil
        var sketch = SnapshotSketch()
        sketch.fetchedAt = now.addingTimeInterval(-60)
        XCTAssertEqual(ReloadGate.reasons(from: shown, to: DisplayFingerprint(sketch.build()), now: now), [.aging])

        sketch.fetchedAt = now.addingTimeInterval(-3 * 3600)
        XCTAssertEqual(ReloadGate.reasons(from: shown, to: DisplayFingerprint(sketch.build()), now: now), [],
                       "numbers already past the dimming line are not worth a reload")
    }

    func testARecentMeasurementInTheCurrentFormatIsNotAging() {
        XCTAssertEqual(reasons({ $0.fetchedAt = self.now }, from: { $0.fetchedAt = self.now.addingTimeInterval(-600) }), [],
                       "shown ten minutes ago, fresher now, nowhere near the line")
    }

    func testAMeasurementTimeAloneIsNotAReason() {
        XCTAssertEqual(reasons({ $0.fetchedAt = self.now }, from: { $0.fetchedAt = self.now.addingTimeInterval(-3600) }), [],
                       "an hour old is not near the line")
        let shown = now.addingTimeInterval(-2 * 3600 + 30)
        XCTAssertEqual(reasons({ $0.fetchedAt = shown }, from: { $0.fetchedAt = shown }), [],
                       "about to dim, but nothing newer to show")
    }

    func testPaceTickAppearingIsOrdinary() {
        XCTAssertEqual(reasons { $0.sevenExpected = 40 }, [.pace])
        XCTAssertEqual(reasons({ $0.sevenExpected = 41 }, from: { $0.sevenExpected = 40 }), [],
                       "the tick moving a point is not worth a reload")
        XCTAssertFalse(ReloadReason.pace.isUrgent)
    }

    func testResetJitterIsIgnored() {
        let soon = now.addingTimeInterval(3600)
        XCTAssertEqual(reasons({ $0.fiveReset = soon.addingTimeInterval(299) }, from: { $0.fiveReset = soon }), [])
    }

    func testResetCorrectionInsideTheHorizonIsUrgent() {
        let soon = now.addingTimeInterval(3600)
        XCTAssertEqual(reasons({ $0.fiveReset = soon.addingTimeInterval(301) }, from: { $0.fiveReset = soon }), [.resetSoon])
        XCTAssertEqual(reasons({ $0.fiveReset = soon }), [.resetSoon], "a reset appearing inside the horizon")
        XCTAssertEqual(reasons({ $0.fiveReset = nil }, from: { $0.fiveReset = soon }), [.resetSoon])
        XCTAssertTrue(ReloadReason.resetSoon.isUrgent)
    }

    func testResetCorrectionOutsideTheHorizonIsOrdinary() {
        let far = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(reasons({ $0.sevenReset = far.addingTimeInterval(600) }, from: { $0.sevenReset = far }), [.resetMoved])
        XCTAssertFalse(ReloadReason.resetMoved.isUrgent)
    }

    func testAPassedResetDisappearingIsNotNews() {
        let past = now.addingTimeInterval(-60)
        XCTAssertEqual(reasons({ $0.fiveReset = nil }, from: { $0.fiveReset = past }), [],
                       "the widget already rolled the window at its planned entry")
    }

    func testSeveralReasonsAreAllReported() {
        let got = reasons({ $0.active = "2"; $0.five = 30; $0.providerStatus = .error }, from: { $0.five = 10 })
        XCTAssertEqual(Set(got), [.status, .active, .percent, .errorText], "the failed provider now shows Unknown error")
    }

    func testAnotherProvidersPercentCounts() {
        var old = SnapshotSketch().build()
        old.providers.append(ProviderUsage(provider: "codex", source: "rollout", status: .ok, accounts: [
            AccountUsage(id: "codex", label: "Codex", active: true, fetchedAt: now, windows: [
                UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 40),
            ]),
        ]))
        var new = old
        new.providers[1].accounts[0].windows[0].usedPct = 41
        XCTAssertEqual(ReloadGate.reasons(from: old, to: new, now: now), [.percent])
    }

    func testFingerprintRoundTripsThroughJSON() throws {
        var sketch = SnapshotSketch()
        sketch.fiveReset = now.addingTimeInterval(600)
        sketch.five = nil
        let fingerprint = DisplayFingerprint(sketch.build())
        let data = try JSONEncoder().encode(fingerprint)
        XCTAssertEqual(try JSONDecoder().decode(DisplayFingerprint.self, from: data), fingerprint)
        XCTAssertEqual(fingerprint.providerOrder, ["claude"])
    }
}
