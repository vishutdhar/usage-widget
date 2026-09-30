import Foundation
import UsageCore

public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

/// The system's login item registration (SMAppService in the app).
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

/// Keeps the app registered as a login item. Each launch reads the system's
/// own status and registers when it is not registered, unless the person
/// turned Start at login off themselves (remembered under
/// `userDisabledKey`).
///
/// Upgrade from the first build, which set "loginItemConfigured" and then
/// registered only once: configured but not registered now is taken as the
/// person's opt-out and kept off. The old flag is then removed, so the
/// toggle's later choices stand. A failed registration from that build
/// looks the same; the status window shows the toggle off, and turning it
/// on registers.
public final class LoginItemManager {
    static let errorKey = "loginItemLastError"
    static let firstBuildKey = "loginItemConfigured"
    /// Set when the person turned Start at login off themselves.
    public static let userDisabledKey = "loginItemUserDisabled"

    private let service: LoginItemService
    private let defaults: LoginItemSettings

    public init(service: LoginItemService, defaults: LoginItemSettings = UserDefaults.standard) {
        self.service = service
        self.defaults = defaults
    }

    public var status: LoginItemStatus { service.status }

    /// The last registration error, kept until a later attempt succeeds.
    public var lastError: String? { defaults.string(forKey: Self.errorKey) }

    public func launch() {
        migrateFirstBuildFlag()
        guard !defaults.bool(forKey: Self.userDisabledKey), service.status == .notRegistered else { return }
        attempt { try service.register() }
    }

    private func migrateFirstBuildFlag() {
        guard defaults.object(forKey: Self.firstBuildKey) != nil else { return }
        if defaults.bool(forKey: Self.firstBuildKey), service.status == .notRegistered,
           defaults.object(forKey: Self.userDisabledKey) == nil {
            defaults.set(true, forKey: Self.userDisabledKey)
        }
        defaults.removeObject(forKey: Self.firstBuildKey)
    }

    public func setEnabled(_ enabled: Bool) {
        let worked = attempt { enabled ? try service.register() : try service.unregister() }
        if worked { defaults.set(!enabled, forKey: Self.userDisabledKey) }
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
