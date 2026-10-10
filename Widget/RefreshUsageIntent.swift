import AppIntents
import Foundation
import UsageCore

/// The widget's refresh button. It writes a numbered request into the
/// shared container and returns at once (`RefreshRequestStore.press`): the
/// extension never runs a process and never waits for the agent. WidgetKit
/// reloads this widget as the intent returns, a reload that is not counted
/// against the budget, and that reload already says "Refreshing…", so the
/// press redraws once. The agent measures every account and, once its
/// snapshot answers the press, asks for the reload that shows the fresh
/// numbers and their "as of".
struct RefreshUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh usage"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        if let directory = SharedContainer.directory() {
            try RefreshRequestStore.press(in: directory, at: Date())
        }
        return .result()
    }
}
