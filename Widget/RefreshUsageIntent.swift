import AppIntents
import Foundation
import UsageCore

/// The widget's refresh button. It only writes a numbered request into the
/// shared container and waits (up to 5 s) for the agent's new snapshot:
/// the extension never runs a process. WidgetKit reloads this widget as
/// soon as the intent returns, a reload that is not counted against the
/// budget, so the fresh numbers show even when the agent's own reload is
/// held back by the daily cap.
struct RefreshUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh usage"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        if let directory = SharedContainer.directory() {
            // A container replaced at its path is re-anchored before use.
            _ = ContainerRoot.revalidate(directory)
            let request = try RefreshRequestStore.request(in: directory, at: Date())
            _ = await RefreshRequestStore.waitForAnswer(in: directory, to: request)
        }
        return .result()
    }
}
