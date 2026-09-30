import AppKit
import Foundation
import Observation
import ServiceManagement
import UsageAgentCore
import UsageCore
import WidgetKit

/// Runs the agent every minute and keeps the state the status window shows.
@MainActor
@Observable
final class AgentController {
    static let interval: Duration = .seconds(60)
    /// How often the agent looks for a press of the refresh button.
    static let refreshCheck: Duration = .seconds(2)

    private(set) var lastWrite: Date?
    private(set) var lastError: String?
    /// The reload scheduler's memory cannot be read or saved.
    private(set) var stateError: String?
    /// Times cswap left a helper holding its output since launch.
    private(set) var helperWarnings = 0
    private(set) var lastReload: Date?
    private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    private(set) var loginItemError: String?
    private(set) var containerPath: String?
    /// Whether the widget shows Codex. Starts on when ~/.codex exists.
    private(set) var showCodex = AgentController.storedShowCodex()
    /// Why the last Codex app-server call failed, while it stands.
    private(set) var codexError: String?
    /// When Codex itself was last asked, and the earliest the next ask can go.
    private(set) var codexCheckedAt: Date?
    private(set) var codexNextCheck: Date?
    private(set) var codexCallsError: String?
    /// The background reload budget: cap, requests of the last day, next.
    private(set) var budget: BudgetStatus?

    @ObservationIgnored private var agent: UsageAgent?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private let loginItems = LoginItemManager(service: SystemLoginItem())
    func start() {
        // Registers on the first launch, and retries on later launches until
        // that has worked once; after that the toggle decides.
        loginItems.launch()
        refreshLoginItemStatus()

        guard let directory = SharedContainer.directory() else {
            lastError = "The shared container is unavailable"
            Log.agent.error("no App Group container")
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        containerPath = directory.path
        // Anchor the container as a directory descriptor once; every file
        // operation after this is relative to it.
        if case .refused(let reason) = ContainerRoot.shared(for: directory) {
            lastError = "The shared container cannot be used: \(reason)"
            Log.agent.error("container refused: \(reason, privacy: .public)")
            return
        }
        let runner = ProcessCswapRunner(warn: { category, detail in
            Log.agent.warning("\(category, privacy: .public): \(detail, privacy: .private)")
        })
        agent = UsageAgent(directory: directory, runner: runner, reload: {
            DispatchQueue.main.async { WidgetCenter.shared.reloadAllTimelines() }
        }, codex: showCodex ? Self.makeCollector() : nil)

        // A windowless agent is a candidate for App Nap, which would stretch
        // a one-minute poll arbitrarily. This keeps the timer honest while
        // still letting the Mac sleep.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Refreshes usage for the desktop widget every minute"
        )

        // One loop, so polls never overlap: a poll every minute, and every
        // two seconds a look for a press of the widget's refresh button,
        // which polls at once.
        loop = Task { [weak self] in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                if clock.now >= next {
                    await self?.tick()
                    next = next.advanced(by: Self.interval)
                    if next < clock.now { next = clock.now.advanced(by: Self.interval) }  // after sleep, no catch-up burst
                } else if await self?.agent?.takeRefreshRequest() == true {
                    await self?.tick(userRequested: true)
                    next = clock.now.advanced(by: Self.interval)
                }
                try? await Task.sleep(for: Self.refreshCheck)
            }
        }
    }

    /// The agent lock failed: keep the login item in order and show why,
    /// but never poll without the lock.
    func startWithoutPolling(reason: String) {
        loginItems.launch()
        refreshLoginItemStatus()
        lastError = reason
    }

    func tick(userRequested: Bool = false) async {
        guard let agent else { return }
        if userRequested { Log.agent.info("refresh requested from the widget") }
        let report = await agent.tick(userRequested: userRequested)
        if report.containerChanged {
            // Once: the loop and the agent end here, and the window says why.
            Log.agent.error("container replaced at its path; polling stopped")
            loop?.cancel()
            loop = nil
            self.agent = nil
            lastError = report.error
            return
        }
        if let writeError = report.writeError {
            lastError = "Could not write the snapshot: \(writeError)"
            // Upstream and file system text can carry personal details.
            Log.agent.error("snapshot not written: \(writeError, privacy: .private)")
            return
        }
        lastWrite = report.writtenAt
        lastError = report.status == .error ? report.error : nil
        if report.codexError != codexError, let error = report.codexError {
            Log.agent.error("codex app-server failed: \(error, privacy: .private)")
        }
        codexError = report.codexError
        codexCheckedAt = report.codexCheckedAt
        codexNextCheck = report.codexNextCheck
        if report.codexCallsError != codexCallsError, let error = report.codexCallsError {
            Log.agent.error("codex call log: \(error, privacy: .private)")
        }
        codexCallsError = report.codexCallsError
        stateError = report.stateError
        helperWarnings = report.helperWarnings
        if let budget = report.budget { self.budget = budget }
        Log.agent.info("tick status=\(report.status.rawValue, privacy: .public) pending=\(report.pending, privacy: .public)")
        if report.status == .error, let error = report.error {
            Log.agent.error("fetch failed: \(error, privacy: .private)")
        }
        if let stateError = report.stateError {
            Log.agent.error("reload state not saved: \(stateError, privacy: .private)")
        }
        if !report.reloadReasons.isEmpty {
            lastReload = report.writtenAt
            let reasons = report.reloadReasons.map(\.rawValue).joined(separator: ",")
            Log.agent.info("reload requested: \(reasons, privacy: .public)")
        }
    }

    // MARK: Codex

    /// The collector, with its once-per-file notes in the debug log (fixed
    /// text, no paths or contents).
    static func makeCollector() -> CodexCollector {
        CodexCollector(debug: { message in Log.agent.debug("codex: \(message, privacy: .public)") })
    }

    static func storedShowCodex() -> Bool {
        CodexPreference.resolve(
            stored: UserDefaults.standard.object(forKey: CodexPreference.key) as? Bool,
            codexHomeExists: FileManager.default.fileExists(atPath: CodexPaths().codexHome.path)
        )
    }

    /// Takes effect from the next poll, at most a minute away.
    func setShowCodex(_ enabled: Bool) {
        showCodex = enabled
        UserDefaults.standard.set(enabled, forKey: CodexPreference.key)
        if !enabled {
            codexError = nil
            codexCheckedAt = nil
            codexNextCheck = nil
        }
        Log.agent.info("show codex: \(enabled, privacy: .public)")
        guard let agent else { return }
        Task { await agent.setCodex(enabled ? Self.makeCollector() : nil) }
    }

    // MARK: login item

    func setStartAtLogin(_ enabled: Bool) {
        loginItems.setEnabled(enabled)
        refreshLoginItemStatus()
    }

    func refreshLoginItemStatus() {
        loginItemStatus = loginItems.status
        loginItemError = loginItems.lastError
        Log.agent.info("login item status: \(String(describing: self.loginItemStatus), privacy: .public)")
        if let error = loginItemError {
            Log.agent.error("login item error: \(error, privacy: .private)")
        }
    }
}

/// SMAppService.mainApp behind the tested `LoginItemService` protocol.
final class SystemLoginItem: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}
