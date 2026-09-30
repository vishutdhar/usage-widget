import XCTest
@testable import UsageCore

/// How a provider's extras (plan, banked resets) reach the widget.
final class ProviderDetailsTests: XCTestCase {
    func testPlanNames() {
        XCTAssertEqual(ProviderDetails.planName("pro"), "Pro")
        XCTAssertEqual(ProviderDetails.planName("plus"), "Plus")
        XCTAssertEqual(ProviderDetails.planName("prolite"), "Pro Lite")
        XCTAssertEqual(ProviderDetails.planName("free"), "Free")
        XCTAssertEqual(ProviderDetails.planName("go"), "Go")
        XCTAssertEqual(ProviderDetails.planName("team"), "Team")
        XCTAssertEqual(ProviderDetails.planName("business"), "Business")
        XCTAssertEqual(ProviderDetails.planName("self_serve_business_usage_based"), "Business")
        XCTAssertEqual(ProviderDetails.planName("enterprise"), "Enterprise")
        XCTAssertEqual(ProviderDetails.planName("ent26"), "Enterprise")
        XCTAssertEqual(ProviderDetails.planName("edu_pro"), "Edu Pro")
        XCTAssertNil(ProviderDetails.planName("unknown"))
        XCTAssertNil(ProviderDetails.planName("something new"), "an unrecognised value is not shown raw")
        XCTAssertNil(ProviderDetails.planName(""))
    }

    func testResetText() {
        XCTAssertEqual(ProviderDetails.resetsText(0), "No resets available")
        XCTAssertEqual(ProviderDetails.resetsText(1), "1 reset available")
        XCTAssertEqual(ProviderDetails.resetsText(2), "2 resets available")
    }

    func testOnlyAPlausibleCountIsShown() {
        func footnote(_ value: JSONValue?) -> String? {
            var extras: [String: JSONValue] = [:]
            extras["resetCreditsAvailable"] = value
            return ProviderDetails.footnote(in: extras)
        }
        XCTAssertEqual(footnote(.number(2)), "2 resets available")
        XCTAssertEqual(footnote(.number(0)), "No resets available")
        XCTAssertNil(footnote(nil), "unknown count")
        XCTAssertNil(footnote(.null), "unknown count")
        XCTAssertNil(footnote(.number(-1)))
        XCTAssertNil(footnote(.number(1.5)))
        XCTAssertNil(footnote(.number(.infinity)))
        XCTAssertNil(footnote(.number(1e12)))
        XCTAssertNil(footnote(.string("2")))
    }

    func testPlanFromExtras() {
        XCTAssertEqual(ProviderDetails.plan(in: ["planType": .string("pro")]), "Pro")
        XCTAssertNil(ProviderDetails.plan(in: ["planType": .null]))
        XCTAssertNil(ProviderDetails.plan(in: [:]))
        XCTAssertNil(ProviderDetails.plan(in: ["planType": .number(1)]))
    }
}

final class CodexWidgetContentTests: XCTestCase {
    let now = utc(2026, 9, 27, 12, 0, 0)

    func snapshot(credits: JSONValue = .number(2), plan: JSONValue = .string("pro")) -> UsageSnapshot {
        UsageSnapshot(writtenAt: now, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                AccountUsage(id: "1", label: "alex@example.com", active: true, fetchedAt: now, windows: [
                    UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: 40),
                ]),
            ]),
            ProviderUsage(provider: "codex", source: "rollout", status: .ok, accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: now, windows: [
                    UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: 35),
                ]),
            ], extras: ["resetCreditsAvailable": credits, "planType": plan]),
        ])
    }

    func testTheCodexAccountCarriesItsPlanAndResets() throws {
        let content = WidgetContent.make(snapshot: snapshot(), at: now)
        let codex = try XCTUnwrap(content.sections.last?.accounts.first)
        XCTAssertEqual(codex.detail, "Pro")
        XCTAssertEqual(codex.footnote, "2 resets available")
        let claude = try XCTUnwrap(content.sections.first?.accounts.first)
        XCTAssertNil(claude.detail)
        XCTAssertNil(claude.footnote)
    }

    func testAnUnknownCountHasNoFootnote() throws {
        let content = WidgetContent.make(snapshot: snapshot(credits: .null, plan: .null), at: now)
        let codex = try XCTUnwrap(content.sections.last?.accounts.first)
        XCTAssertNil(codex.detail)
        XCTAssertNil(codex.footnote)
    }

    /// The account the medium widget features, then other providers, then
    /// the featured provider's other accounts.
    func testPriorityPutsOtherProvidersRightAfterTheFeaturedAccount() {
        var snap = snapshot()
        snap.providers[0].accounts.append(AccountUsage(id: "2", label: "sam@example.com", active: false, fetchedAt: now,
                                                       windows: []))
        snap.providers[0].accounts.insert(AccountUsage(id: "0", label: "zoe@example.com", active: false, fetchedAt: now,
                                                       windows: []), at: 0)
        let content = WidgetContent.make(snapshot: snap, at: now)
        XCTAssertEqual(content.featured?.id, "1", "the active account")
        XCTAssertEqual(content.accountsByPriority.map(\.id), ["1", "codex", "0", "2"])
    }

    func testWithoutAnActiveAccountTheFirstIsFeatured() {
        var snap = snapshot()
        snap.providers[0].accounts[0].active = false
        let content = WidgetContent.make(snapshot: snap, at: now)
        XCTAssertEqual(content.accountsByPriority.map(\.id), ["1", "codex"])
    }
}

final class CodexReloadTests: XCTestCase {
    let now = utc(2026, 9, 27, 12, 0, 0)

    func snapshot(credits: JSONValue, plan: JSONValue = .string("pro"), pct: Double = 35,
                  status: ProviderUsage.Status = .ok) -> UsageSnapshot {
        var snap = SnapshotSketch().build()
        snap.providers.append(ProviderUsage(provider: "codex", source: "app-server", status: status, accounts: [
            AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: now, windows: [
                UsageWindow(kind: .weekly, name: "Weekly", windowSeconds: 604_800, usedPct: pct),
            ]),
        ], extras: ["resetCreditsAvailable": credits, "planType": plan]))
        return snap
    }

    func testABankedResetCountChangeIsOrdinary() {
        let got = ReloadGate.reasons(from: snapshot(credits: .number(2)), to: snapshot(credits: .number(1)), now: now)
        XCTAssertEqual(got, [.details])
        XCTAssertFalse(ReloadReason.details.isUrgent)
    }

    func testAPlanChangeIsADetail() {
        let got = ReloadGate.reasons(from: snapshot(credits: .number(2)),
                                     to: snapshot(credits: .number(2), plan: .string("plus")), now: now)
        XCTAssertEqual(got, [.details])
    }

    func testTheCountBecomingKnownIsADetail() {
        let got = ReloadGate.reasons(from: snapshot(credits: .null), to: snapshot(credits: .number(2)), now: now)
        XCTAssertEqual(got, [.details])
    }

    /// Codex goes through the same classes as every other provider.
    func testCodexBandAndStatusAreUrgentAndItsPercentOrdinary() {
        XCTAssertEqual(ReloadGate.reasons(from: snapshot(credits: .number(2), pct: 35),
                                          to: snapshot(credits: .number(2), pct: 39), now: now), [.percent])
        XCTAssertEqual(ReloadGate.reasons(from: snapshot(credits: .number(2), pct: 69),
                                          to: snapshot(credits: .number(2), pct: 70), now: now), [.band, .percent])
        XCTAssertEqual(ReloadGate.reasons(from: snapshot(credits: .number(2)),
                                          to: snapshot(credits: .number(2), status: .error), now: now), [.status, .errorText])
    }

    func testExtrasTheWidgetDoesNotShowAreIgnored() {
        var old = snapshot(credits: .number(2))
        var new = old
        old.providers[1].extras["somethingElse"] = .number(1)
        new.providers[1].extras["somethingElse"] = .number(5)
        XCTAssertEqual(ReloadGate.reasons(from: old, to: new, now: now), [])
    }

    /// A fingerprint saved before details existed still reads, and a
    /// provider without details does not count as changed.
    func testAFingerprintWithoutDetailsStillReads() throws {
        let plain = SnapshotSketch().build()
        let data = try JSONEncoder().encode(DisplayFingerprint(plain))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var providers = try XCTUnwrap(object["providers"] as? [String: Any])
        var claude = try XCTUnwrap(providers["claude"] as? [String: Any])
        claude.removeValue(forKey: "details")
        providers["claude"] = claude
        object["providers"] = providers
        let old = try JSONDecoder().decode(DisplayFingerprint.self,
                                           from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(ReloadGate.reasons(from: old, to: DisplayFingerprint(plain), now: now), [])
    }
}
