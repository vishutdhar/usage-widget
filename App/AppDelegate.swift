import AppKit
import OSLog
import os
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

    /// Set by a confirmed Stop: the one quit (besides the end of the
    /// session) that exits 0, which launchd leaves stopped.
    private var stopConfirmed = false
    private var termination: AgentTermination = .unrequested

    /// launchd started this copy: it is the supervised one.
    private var startedByLaunchd = false
    /// Checks, while this copy runs the agent unsupervised, whether the job
    /// can take over now.
    private var supervisionCheck: Timer?
    private var handingOver = false
    /// Set while a lock let go in a handover that did not happen is not yet
    /// taken back; polling stays paused until it is.
    private var recovery: LockRecovery?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // First, whether macOS opened the app at login or launchd started
        // its job (at login, or again after a crash): such a launch shows no
        // window, and a duplicate one must leave quietly instead of opening
        // the running copy's window, so this is known before the handover.
        startedByLaunchd = LaunchAgentJob.startedByLaunchd(arguments: CommandLine.arguments)
        if startedByLaunchd {
            launchedAsLoginItem = true
        } else if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
               == OSType(keyAELaunchedAsLogInItem) {
            launchedAsLoginItem = true
        }

        // A copy launchd did not start hands the agent to the job, so the
        // running copy is always the supervised one. It runs the agent
        // itself only when the job cannot, and the status window says why.
        if !startedByLaunchd {
            switch Self.handOverToJob(show: !launchedAsLoginItem) {
            case .handedOver:
                Log.agent.info("handed over to the launchd job")
                exit(0)
            case .runUnsupervised(let note):
                Log.agent.info("running unsupervised: \(note, privacy: .public)")
                controller.supervisionNote = note
            }
        }

        var lock: InstanceLock.Outcome.Kind = .acquired
        if let directory = SharedContainer.directory() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("agent.lock")
            var held: InstanceLock?
            lock = LaunchDecision.acquire(retrying: startedByLaunchd, attempt: {
                let outcome = InstanceLock.acquire(at: url)
                held = outcome.lock
                return outcome.kind
            }, sleep: { Thread.sleep(forTimeInterval: $0) })
            instanceLock = held
            Self.logPublishError(of: held)
        }

        let action = LaunchDecision.decide(lock: lock, loginLaunch: launchedAsLoginItem,
                                           startedByLaunchd: startedByLaunchd)
        if case .stayWithoutPolling(let message) = action { lockError = message }
        carryOut(action)

        // Only the copy that stays (it holds the lock) observes these, so
        // its answer tells an opened copy the handover is done.
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showStatusNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showStatusWindow()
                Self.answer()
            }
        }
        // `Usage Widget --stop` (the install script) stops as Stop does.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(LaunchAgentJob.stopNotification), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.agent.info("stop requested from the command line")
                self?.stop()
            }
        }
        controller.stopHandler = { [weak self] in self?.stop() }
        controller.loginItemChanged = { [weak self] in self?.handOverIfTheJobCanRun() }
        if !startedByLaunchd, controller.supervisionNote != nil {
            supervisionCheck = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    // A lock not yet taken back is retried before anything else.
                    if let recovery = self?.recovery, recovery.paused {
                        recovery.attempt()
                    } else {
                        self?.handOverIfTheJobCanRun()
                    }
                }
            }
        }
    }

    // MARK: supervision

    private static func answer() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(LaunchAgentJob.answerNotification), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// The agent lock's file, when the shared container is there.
    private static func lockURL() -> URL? {
        SharedContainer.directory()?.appendingPathComponent("agent.lock")
    }

    /// The takeover's effects; `releaseOwnLock` lets go of this copy's lock
    /// (nothing for a copy just opened, which holds none).
    nonisolated private static func takeoverEffects(lockURL: URL?, releaseOwnLock: @escaping () -> Void) -> Takeover.Effects {
        Takeover.Effects(
            startJob: { startJob() },
            releaseOwnLock: releaseOwnLock,
            probe: { lockURL.map(InstanceLock.probe(at:)) ?? .failed("no shared container") },
            isAlive: { kill($0, 0) == 0 },
            jobPid: { jobPid() },
            sleep: { Thread.sleep(forTimeInterval: $0) })
    }

    /// Registers the job if it should be, starts it, and confirms its copy
    /// took the lock; a manual open then asks that copy for its window.
    private static func handOverToJob(show: Bool) -> ManualOpen.Outcome {
        let loginItems = AgentController.makeLoginItems()
        loginItems.launch()
        let outcome = ManualOpen.run(readiness: loginItems.readiness, ownPid: getpid(),
                                     effects: takeoverEffects(lockURL: lockURL(), releaseOwnLock: {}))
        if outcome == .handedOver, show { askTheHolderForItsWindow() }
        return outcome
    }

    /// The holder starts observing just after it takes the lock, so the
    /// request is repeated until it answers (a few seconds at most).
    private static func askTheHolderForItsWindow() {
        // Set from the observer, read by the wait below, both on this thread.
        let answered = OSAllocatedUnfairLock(initialState: false)
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(LaunchAgentJob.answerNotification), object: nil, queue: nil
        ) { _ in answered.withLock { $0 = true } }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }
        let end = Date().addingTimeInterval(3)
        while !answered.withLock({ $0 }), Date() < end {
            DistributedNotificationCenter.default().postNotificationName(
                showStatusNotification, object: nil, userInfo: nil, deliverImmediately: true)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
        }
    }

    /// The launchd job's pid, from `launchctl print`; nil when not running.
    nonisolated static func jobPid() -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(LaunchAgentJob.label)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return LaunchAgentJob.pid(inPrint: String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    /// `launchctl kickstart`: starts the job (0 also when it already runs).
    nonisolated static func startJob() -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(LaunchAgentJob.label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            Log.agent.error("launchctl kickstart failed: \(error.localizedDescription, privacy: .public)")
            return -1
        }
    }

    /// An unsupervised copy (opened by hand while the job could not run)
    /// gives the agent to the job once it can. It stops polling, starts the
    /// job, lets go of the lock, and leaves only when another live process
    /// holds the lock; otherwise it takes the lock back, polls again, says
    /// why in the status window, and tries at the next check.
    private func handOverIfTheJobCanRun() {
        guard !startedByLaunchd, !handingOver, controller.supervisionNote != nil,
              AgentController.makeLoginItems().readiness == .ready, let url = Self.lockURL() else { return }
        handingOver = true
        Log.agent.info("the launchd job can run the agent now; handing over")
        let held = instanceLock
        Task { @MainActor in
            await controller.pausePolling()
            let outcome = await Task.detached {
                Takeover.run(ownPid: getpid(),
                             effects: AppDelegate.takeoverEffects(lockURL: url, releaseOwnLock: { held?.release() }))
            }.value
            switch outcome {
            case .confirmed(let pid):
                Log.agent.info("launchd's copy took over (pid \(pid, privacy: .public)); leaving")
                instanceLock = nil
                stop()
            case .jobNotStarted(let status):
                keepRunning(note: ManualOpen.note(for: "launchd could not start the agent (launchctl exit \(status))"),
                            lockURL: url)
            case .notTaken:
                keepRunning(note: ManualOpen.notTakenNote, lockURL: url)
            }
        }
    }

    /// A handover that did not happen: the lock back (when it was let go)
    /// and polling again.
    private func keepRunning(note: String, lockURL: URL) {
        Log.agent.info("handover did not happen: \(note, privacy: .public)")
        controller.supervisionNote = note
        guard instanceLock?.isReleased ?? true else {
            // kickstart failed before the lock was let go.
            controller.resumePolling()
            handingOver = false
            return
        }
        let recovery = LockRecovery(
            acquire: { [weak self] in
                let outcome = InstanceLock.acquire(at: lockURL)
                self?.instanceLock = outcome.lock
                Self.logPublishError(of: outcome.lock)
                return outcome.kind
            },
            resume: { [weak self] in
                guard let self else { return }
                self.controller.supervisionNote = note
                self.controller.resumePolling()
                self.handingOver = false
                self.recovery = nil
            },
            leave: { [weak self] in
                // Taken just after the window closed: that copy runs the agent.
                Log.agent.info("another copy took the lock after all; leaving")
                self?.instanceLock = nil
                self?.stop()
            },
            show: { [weak self] message in
                Log.agent.error("\(message, privacy: .public)")
                self?.controller.supervisionNote = message
            })
        self.recovery = recovery
        recovery.attempt()
    }

    /// The holder's pid could not be written: a copy handing over then
    /// cannot confirm a takeover, so say it once for this lock.
    nonisolated private static func logPublishError(of lock: InstanceLock?) {
        if let error = lock?.publishError {
            Log.agent.error("could not write the holder pid into the agent lock: \(error, privacy: .public)")
        }
    }

    /// Ends the app with status 0, so launchd does not start it again.
    func stop() {
        stopConfirmed = true
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination = AgentTermination.classify(stopConfirmed: stopConfirmed, quitReason: Self.quitReason())
        Log.agent.info("terminating: \(String(describing: self.termination), privacy: .public)")
        return .terminateNow
    }

    /// AppKit would exit 0 after this; any quit but a confirmed Stop or the
    /// end of the session exits 1 instead, and launchd restarts the agent.
    func applicationWillTerminate(_ notification: Notification) {
        let status = termination.exitStatus
        if status != 0 { exit(status) }
    }

    /// The reason a quit Apple Event carries (log out, restart, shut down),
    /// or nil for a quit without one.
    private static func quitReason() -> UInt32? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return nil }
        let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        return reason?.enumCodeValue
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
            exit(action.exitStatus ?? 0)
        case .exitQuietly:
            Log.agent.info("login launch while another instance runs; leaving quietly")
            exit(action.exitStatus ?? 0)
        case .leaveForRetry:
            // Non-zero, so KeepAlive starts launchd's copy again later.
            Log.agent.info("launchd start while another instance holds the lock; leaving for a retry")
            exit(action.exitStatus ?? 1)
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
