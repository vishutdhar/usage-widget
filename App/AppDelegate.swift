import AppKit
import OSLog
import SwiftUI
import UsageAgentCore
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Posted by a second copy of the app to the one already running.
    static let showStatusNotification = Notification.Name("com.vishutdhar.usagewidget.showStatus")

    let controller = AgentController()
    private var window: NSWindow?
    private var launchedAsLoginItem = false
    /// Held for the life of the process: one agent polls and writes at a time.
    private var instanceLock: InstanceLock?

    /// Set when the agent lock itself failed: the app stays open to say so,
    /// without polling.
    private var lockError: String?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // First, whether macOS opened the app at login: a duplicate login
        // launch must leave quietly instead of opening the running copy's
        // window, so this is known before the handover.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
               == OSType(keyAELaunchedAsLogInItem) {
            launchedAsLoginItem = true
        }

        var lock: InstanceLock.Outcome.Kind = .acquired
        if let directory = SharedContainer.directory() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let outcome = InstanceLock.acquire(at: directory.appendingPathComponent("agent.lock"))
            instanceLock = outcome.lock
            lock = outcome.kind
        }

        let action = LaunchDecision.decide(lock: lock, loginLaunch: launchedAsLoginItem)
        if case .stayWithoutPolling(let message) = action { lockError = message }
        carryOut(action)

        DistributedNotificationCenter.default().addObserver(
            forName: Self.showStatusNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showStatusWindow() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.agent.info("launched, login item launch: \(self.launchedAsLoginItem, privacy: .public)")
        if let lockError {
            Log.agent.error("agent lock failed: \(lockError, privacy: .private)")
            controller.startWithoutPolling(reason: lockError)
            showStatusWindow()
            return
        }
        controller.start()
        if !launchedAsLoginItem {
            showStatusWindow()
        }
    }

    /// Leaves (or hands over) when another copy runs the agent.
    private func carryOut(_ action: LaunchAction) {
        switch action {
        case .run, .stayWithoutPolling:
            break
        case .handOverAndExit:
            // Another copy (a different build, or `open -n`) already runs the
            // agent: ask it to show its window, and leave.
            DistributedNotificationCenter.default().postNotificationName(
                Self.showStatusNotification, object: nil, userInfo: nil, deliverImmediately: true)
            Log.agent.info("another instance holds the agent lock; handing over")
            exit(0)
        case .exitQuietly:
            Log.agent.info("login launch while another instance runs; leaving quietly")
            exit(0)
        }
    }

    /// Opening the app while it runs (Finder, Spotlight, or a click on the
    /// widget) shows the status window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showStatusWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showStatusWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: StatusView(controller: controller))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Usage Widget"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        controller.refreshLoginItemStatus()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

enum Log {
    static let agent = Logger(subsystem: "com.vishutdhar.usagewidget", category: "agent")
}
