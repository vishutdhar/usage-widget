import SwiftUI

/// A background agent (no Dock icon) that keeps the desktop widget's
/// snapshot fresh. Its only window is a small status window, shown when
/// the app is opened again while it is already running.
@main
struct UsageWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains(StateDump.refreshFlag) {
            exit(StateDump.requestRefresh())
        }
        if let lines = StateDump.requestedLines(from: CommandLine.arguments) {
            exit(StateDump.run(lines: lines))
        }
    }

    var body: some Scene {
        Settings {
            StatusView(controller: appDelegate.controller)
        }
    }
}
