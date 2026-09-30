import SwiftUI
import UsageCore
import UsageWidgetUI
import WidgetKit

struct UsageWidget: Widget {
    static let kind = "UsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UsageTimelineProvider()) { entry in
            UsageEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(nsColor: .windowBackgroundColor)
                }
        }
        .configurationDisplayName("Usage")
        .description("Usage limits and reset times for every account.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct UsageEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        UsageWidgetView(content: entry.content, size: family == .systemLarge ? .large : .medium,
                        refreshControl: AnyView(
                            Button(intent: RefreshUsageIntent()) { RefreshButtonLabel() }
                                .buttonStyle(.plain)
                                .help("Refresh")
                        ))
    }
}
