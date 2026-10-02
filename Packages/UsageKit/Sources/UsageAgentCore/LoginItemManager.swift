import Foundation
import UsageCore

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

/// The system's login item registration (SMAppService in the app: the
/// agent's launchd job, and the app login item earlier builds used).
public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// Where the login item choices are remembered: UserDefaults in the app,
/// an in-memory store in tests, so tests leave nothing in
/// ~/Library/Preferences.
public protocol LoginItemSettings: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func bool(forKey defaultName: String) -> Bool
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: LoginItemSettings {}

/// Keeps the agent's launchd job registered. Each launch reads the system's
/// own status and registers when it is not registered (or, for a job never
/// registered, not found), unless the person
/// turned Start at login off themselves (remembered under
/// `userDisabledKey`).
///
/// Upgrade from the first build, which set "loginItemConfigured" and then
/// registered only once: configured but not registered now is taken as the
/// person's opt-out and kept off. The old flag is then removed, so the
/// toggle's later choices stand. A failed registration from that build
/// looks the same; the status window shows the toggle off, and turning it
/// on registers.
///
/// Upgrade from builds that registered the app itself (`legacy`): that
/// login item is removed once, and only then is the launchd job registered,
/// so the app never starts twice at login. The person's off choice carries
/// over.
public final class LoginItemManager {
    static let errorKey = "loginItemLastError"
    static let firstBuildKey = "loginItemConfigured"
    /// Set once the move to the launchd job is recorded (before the old
    /// item is removed).
    static let movedToJobKey = "loginItemMovedToLaunchAgent"
    /// Set while the old app login item still has to be removed.
    static let legacyRemovalKey = "loginItemLegacyRemovalPending"
    /// Set when that item had been turned off in System Settings; cleared
    /// when the person turns Start at login on.
    static let offInSettingsKey = "loginItemOffInSystemSettings"
    public static let offInSettingsNote = "Start at login was turned off in System Settings"
    /// Set when the person turned Start at login off themselves.
    public static let userDisabledKey = "loginItemUserDisabled"

    private let service: LoginItemService
    private let legacy: LoginItemService?
    private let defaults: LoginItemSettings

    public init(service: LoginItemService, legacy: LoginItemService? = nil,
                defaults: LoginItemSettings = UserDefaults.standard) {
        self.service = service
        self.legacy = legacy
        self.defaults = defaults
    }

    public var status: LoginItemStatus { service.status }

    /// The last registration error, kept until a later attempt succeeds.
    public var lastError: String? { defaults.string(forKey: Self.errorKey) }

    public func launch() {
        migrateFirstBuildFlag()
        recordTheMove()
        // A launchd job never registered reads as not found.
        if !defaults.bool(forKey: Self.userDisabledKey),
           service.status == .notRegistered || service.status == .notFound {
            attempt { try service.register() }
        }
        // Last: removing the old item can end this process when that item
        // started it, and everything above is already saved.
        removeLegacyItem()
    }

    private func migrateFirstBuildFlag() {
        guard defaults.object(forKey: Self.firstBuildKey) != nil else { return }
        if defaults.bool(forKey: Self.firstBuildKey), (legacy ?? service).status == .notRegistered,
           defaults.object(forKey: Self.userDisabledKey) == nil {
            defaults.set(true, forKey: Self.userDisabledKey)
        }
        defaults.removeObject(forKey: Self.firstBuildKey)
    }

    /// Records the move from the earlier builds' app login item once: an
    /// item turned off in System Settings carries over as Start at login
    /// off, and an item still registered is marked for removal.
    private func recordTheMove() {
        guard let legacy, !defaults.bool(forKey: Self.movedToJobKey) else { return }
        switch legacy.status {
        case .enabled:
            defaults.set(true, forKey: Self.legacyRemovalKey)
        case .requiresApproval:
            // Turned off in System Settings: the person's choice, kept off.
            defaults.set(true, forKey: Self.userDisabledKey)
            defaults.set(true, forKey: Self.offInSettingsKey)
            defaults.set(true, forKey: Self.legacyRemovalKey)
        case .notRegistered, .notFound:
            break
        }
        defaults.set(true, forKey: Self.movedToJobKey)
    }

    /// Removes the old item while that is pending, but only once the job
    /// replacing it reads enabled (or Start at login is off, so nothing
    /// should start at login): a failed or pending replacement keeps the
    /// only working item. A failure (or this process ending) leaves it
    /// pending for the next launch.
    private func removeLegacyItem() {
        guard let legacy, defaults.bool(forKey: Self.legacyRemovalKey) else { return }
        guard service.status == .enabled || defaults.bool(forKey: Self.userDisabledKey) else { return }
        if legacy.status == .enabled || legacy.status == .requiresApproval {
            // An error the job's registration recorded in this launch stays:
            // this removal neither clears it nor writes over it.
            do {
                try legacy.unregister()
            } catch {
                if lastError == nil {
                    defaults.set(Redactor.redactEmails(error.localizedDescription), forKey: Self.errorKey)
                }
                return
            }
        }
        defaults.removeObject(forKey: Self.legacyRemovalKey)
    }

    /// What the app does after the toggle changed: off, once the job is
    /// really removed, ends the app (exit 0) whichever copy runs, a copy
    /// running unsupervised included, so "off" means nothing runs.
    public enum ToggleOutcome: Equatable, Sendable { case keepRunning, stopTheApp }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> ToggleOutcome {
        if enabled {
            if attempt({ try service.register() }) {
                defaults.set(false, forKey: Self.userDisabledKey)
                defaults.removeObject(forKey: Self.offInSettingsKey)
            }
            return .keepRunning
        }
        // Removing the job ends the running agent (launchd stops it), so
        // the choice is saved first and put back if the removal fails.
        let before = defaults.object(forKey: Self.userDisabledKey)
        defaults.set(true, forKey: Self.userDisabledKey)
        if !attempt({ try service.unregister() }) {
            defaults.set(before, forKey: Self.userDisabledKey)
            return .keepRunning
        }
        return .stopTheApp
    }

    /// Whether the job can run the agent now, or why not.
    public var readiness: JobReadiness {
        if defaults.bool(forKey: Self.offInSettingsKey) { return .unavailable(Self.offInSettingsNote) }
        if defaults.bool(forKey: Self.userDisabledKey) { return .unavailable("Start at login is off") }
        switch service.status {
        case .enabled:
            return .ready
        case .requiresApproval:
            return .unavailable("Start at login needs approval in System Settings, General, Login Items")
        case .notRegistered, .notFound:
            return .unavailable(lastError.map { "the launchd job is not registered: \($0)" }
                                ?? "the launchd job is not registered")
        }
    }

    /// A note for the status window about the person's choice, if any.
    public var note: String? {
        defaults.bool(forKey: Self.offInSettingsKey) ? Self.offInSettingsNote : nil
    }

    /// After the app was replaced, the new copy registers the job again
    /// (off, then on), as a replaced app needs. Start at login off stays
    /// off, and a job awaiting approval is left to System Settings.
    /// What registering the job again from a new copy came to.
    public enum Registration: Equatable, Sendable {
        case registered
        /// Not registered by the person's choice, or awaiting approval.
        case leftOff(String)
        /// Registration failed: an error, not a choice.
        case failed(String)
    }

    /// After the app was replaced, the new copy registers the job again
    /// (off, then on), as a replaced app needs. Start at login off stays
    /// off, and a job awaiting approval is left to System Settings.
    public func registerAgain() -> Registration {
        // Errors from earlier operations go first; none recorded from here
        // on is cleared.
        defaults.removeObject(forKey: Self.errorKey)
        if !defaults.bool(forKey: Self.userDisabledKey), service.status == .enabled {
            // Not taken off means not registered again: an error to report.
            guard attempt({ try service.unregister() }) else { return .failed(lastError ?? "unregister failed") }
        }
        launch()
        if service.status == .enabled { return .registered }
        if let error = lastError { return .failed(error) }
        if case .unavailable(let reason) = readiness { return .leftOff(reason) }
        return .failed("the launchd job is not registered")
    }

    @discardableResult
    private func attempt(_ change: () throws -> Void) -> Bool {
        do {
            try change()
            defaults.removeObject(forKey: Self.errorKey)
            return true
        } catch {
            defaults.set(Redactor.redactEmails(error.localizedDescription), forKey: Self.errorKey)
            return false
        }
    }
}
