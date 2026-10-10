import Foundation

/// The agent's reload log lines: one per reload it asks for, numbered, and
/// marked background (a change worth showing) or press (one for each
/// answered press). `requests24h` counts the background ones.
public enum ReloadLog {
    public enum Kind: String, Sendable {
        case background
        case press
    }

    public static func line(at date: Date, reasons: [ReloadReason], urgent: Bool, status: String, requests24h: Int,
                            id: Int, kind: Kind) -> String {
        "\(ISODate.format(date)) reload reasons=\(reasons.map(\.rawValue).joined(separator: ","))"
            + " urgent=\(urgent ? "yes" : "no") status=\(status) requests24h=\(requests24h) id=\(id) kind=\(kind.rawValue)"
    }
}

/// The widget's timeline log lines: one per getTimeline call, with the
/// family and the snapshot it loaded (write number, time, age). Nothing is
/// inferred about what caused the call; the README says how to read the
/// two logs side by side.
public enum TimelineLog {
    public static func line(at date: Date, family: String, snapshot: UsageSnapshot?, entries: Int,
                            reloadAfter: Date) -> String {
        let written = snapshot.map { ISODate.format($0.writtenAt) } ?? "none"
        let age = snapshot.map { String(Int(min(max(date.timeIntervalSince($0.writtenAt), -1e9), 1e9))) } ?? "none"
        let number = snapshot?.writeSequence.map(String.init) ?? "none"
        return "\(ISODate.format(date)) getTimeline family=\(family) snapshot=\(number) snapshotWrittenAt=\(written)"
            + " snapshotAgeSec=\(age) entries=\(entries) reloadAfter=\(ISODate.format(reloadAfter))"
    }
}
