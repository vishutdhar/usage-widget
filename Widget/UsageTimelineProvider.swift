import Foundation
import UsageCore
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let content: WidgetContent
}

/// Reads the snapshot the agent writes. It never runs a process: the widget
/// is sandboxed and sees only the shared App Group container.
struct UsageTimelineProvider: TimelineProvider {
    /// Anchors the shared container once for this process; every file the
    /// provider reads after this goes through that directory descriptor.
    init() {
        if let directory = SharedContainer.directory() { _ = ContainerRoot.shared(for: directory) }
    }

    func placeholder(in context: Context) -> UsageEntry {
        let now = Date()
        return UsageEntry(date: now, content: WidgetContent.make(snapshot: SampleSnapshot.make(now: now), at: now))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (UsageEntry) -> Void) {
        let now = Date()
        let snapshot = readSnapshot() ?? (context.isPreview ? SampleSnapshot.make(now: now) : nil)
        completion(UsageEntry(date: now, content: WidgetContent.make(snapshot: snapshot, at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let snapshot = readSnapshot()
        let refresh = SharedContainer.directory().flatMap(RefreshRequestStore.read(in:))
        // Entries at each upcoming reset bucket and at the staleness crossing;
        // each entry computes its own ages, so a later entry looks as old as
        // it will be. While a press of the refresh button is being answered
        // the footer says "Refreshing…", and an entry marks where that ends.
        let plan = TimelinePlan.plan(for: snapshot, now: now, refresh: refresh)
        let entries = plan.entries.map { date in
            UsageEntry(date: date, content: WidgetContent.make(snapshot: snapshot, at: date, refresh: refresh))
        }
        logTimelineCall(now: now, family: context.family, snapshot: snapshot, plan: plan)
        completion(Timeline(entries: entries, policy: .after(plan.reloadAfter)))
    }

    private func readSnapshot() -> UsageSnapshot? {
        guard let directory = SharedContainer.directory() else { return nil }
        // A container replaced at its path is re-anchored before use.
        _ = ContainerRoot.revalidate(directory)
        return SnapshotStore.read(from: directory.appendingPathComponent(SharedContainer.snapshotFileName))
    }

    /// One line per getTimeline call: the family and the snapshot it
    /// loaded, for reading beside the agent's reload log (see the README).
    private func logTimelineCall(now: Date, family: WidgetFamily, snapshot: UsageSnapshot?, plan: TimelinePlan.Plan) {
        guard let directory = SharedContainer.directory() else { return }
        let line = TimelineLog.line(at: now, family: family.logName, snapshot: snapshot, entries: plan.entries.count,
                                    reloadAfter: plan.reloadAfter)
        try? CappedLog.append(line, to: directory.appendingPathComponent(SharedContainer.widgetLogFileName),
                              cap: SharedContainer.logCap)
    }
}

private extension WidgetFamily {
    var logName: String {
        switch self {
        case .systemSmall: return "small"
        case .systemMedium: return "medium"
        case .systemLarge: return "large"
        case .systemExtraLarge: return "extraLarge"
        default: return "other"
        }
    }
}

/// Stand-in data for the widget gallery before the agent has written
/// anything. Addresses use example.com.
enum SampleSnapshot {
    static func make(now: Date) -> UsageSnapshot {
        func window(_ kind: UsageWindow.Kind, _ name: String, _ pct: Double, hours: Double?, expected: Double? = nil) -> UsageWindow {
            UsageWindow(kind: kind, name: name, windowSeconds: kind == .session ? WindowLength.fiveHours : WindowLength.sevenDays,
                        usedPct: pct, resetsAt: hours.map { now.addingTimeInterval($0 * 3600) }, expectedPct: expected)
        }
        return UsageSnapshot(writtenAt: now, providers: [
            ProviderUsage(provider: "claude", source: "sample", status: .ok, accounts: [
                AccountUsage(id: "1", label: "you@example.com", active: true, fetchedAt: now, windows: [
                    window(.session, "5h", 34, hours: 3.5),
                    window(.weekly, "7d", 58, hours: 60, expected: 64),
                ]),
                AccountUsage(id: "2", label: "work@example.com", active: false, fetchedAt: now, windows: [
                    window(.session, "5h", 0, hours: nil),
                    window(.weekly, "7d", 76, hours: 100, expected: 40),
                ]),
            ]),
        ])
    }
}
