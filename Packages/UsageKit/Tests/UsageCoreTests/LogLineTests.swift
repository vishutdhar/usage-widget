import XCTest
@testable import UsageCore

/// The two logs kept for reading by hand: the agent's reload lines and the
/// widget's plain getTimeline lines.
final class LogLineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testReloadLinesCarryTheirNumberAndKind() {
        let background = ReloadLog.line(at: t0, reasons: [.percent], urgent: false, status: "ok", requests24h: 3, id: 3,
                                        kind: .background)
        XCTAssertEqual(background, "\(ISODate.format(t0)) reload reasons=percent urgent=no status=ok requests24h=3 id=3 kind=background")
        XCTAssertTrue(ReloadLog.line(at: t0, reasons: [.user], urgent: true, status: "ok", requests24h: 4, id: 4, kind: .press)
            .hasSuffix(" id=4 kind=press"))
    }

    /// A getTimeline line: the family and the snapshot it loaded (its write
    /// number and time), nothing about causes.
    func testTimelineLinesAreThePlainFacts() {
        let snapshot = UsageSnapshot(writtenAt: t0, providers: [], writeSequence: 12, writerId: "W")
        let line = TimelineLog.line(at: t0.addingTimeInterval(4), family: "large", snapshot: snapshot, entries: 3,
                                    reloadAfter: t0.addingTimeInterval(10_804))
        XCTAssertEqual(line, "\(ISODate.format(t0.addingTimeInterval(4))) getTimeline family=large snapshot=12"
                       + " snapshotWrittenAt=\(ISODate.format(t0)) snapshotAgeSec=4 entries=3"
                       + " reloadAfter=\(ISODate.format(t0.addingTimeInterval(10_804)))")
        XCTAssertTrue(TimelineLog.line(at: t0, family: "medium", snapshot: nil, entries: 1, reloadAfter: t0)
            .contains(" snapshot=none snapshotWrittenAt=none snapshotAgeSec=none "))
    }
}
