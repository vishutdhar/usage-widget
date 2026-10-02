import SwiftUI
import UsageAgentCore

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
        if CommandLine.arguments.dropFirst().contains(LaunchAgentJob.stopArgument) {
            // Stops the running agent as a confirmed Stop does.
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(LaunchAgentJob.stopNotification), object: nil, userInfo: nil,
                deliverImmediately: true)
            exit(0)
        }
        if CommandLine.arguments.dropFirst().contains(LaunchAgentJob.registerArgument) {
            // The install script, from the newly installed copy.
            switch AgentController.makeLoginItems().registerAgain() {
            case .registered:
                print("Launchd job: registered")
                exit(0)
            case .leftOff(let reason):
                print("Launchd job: left off: \(reason)")
                exit(3)
            case .failed(let error):
                FileHandle.standardError.write(Data("Launchd job: registration failed: \(error)\n".utf8))
                exit(4)
            }
        }
        if let choice = AgentController.startAtLoginChoice(from: CommandLine.arguments) {
            exit(AgentController.setStartAtLoginFromCommandLine(choice))
        }
    }

    var body: some Scene {
        Settings {
            StatusView(controller: appDelegate.controller)
        }
    }
}
