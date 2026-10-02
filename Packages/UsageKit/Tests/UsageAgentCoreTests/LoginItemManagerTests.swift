import XCTest
import UsageCore
@testable import UsageAgentCore

final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var failures: [String] = []
    var registerCalls = 0
    var unregisterCalls = 0
    /// Runs as unregister starts: launchd ends a running job there, so
    /// anything not saved by then is lost.
    var onUnregister: (() -> Void)?

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func register() throws {
        registerCalls += 1
        if !failures.isEmpty { throw Failure(message: failures.removeFirst()) }
        status = .enabled
    }

    func unregister() throws {
        unregisterCalls += 1
        onUnregister?()
        if !failures.isEmpty { throw Failure(message: failures.removeFirst()) }
        status = .notRegistered
    }
}

/// Dictionary-backed settings with the UserDefaults reading rules the
/// manager relies on: a missing or non-Bool key reads as false.
final class MemorySettings: LoginItemSettings {
    private(set) var values: [String: Any] = [:]
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

final class LoginItemManagerTests: XCTestCase {
    var defaults: MemorySettings!

    override func setUp() {
        defaults = MemorySettings()
    }

    override func tearDown() {
        defaults = nil
    }

    func manager(_ service: FakeLoginItemService) -> LoginItemManager {
        LoginItemManager(service: service, defaults: defaults)
    }

    func testEachLaunchRegistersWhenTheSystemSaysNotRegistered() {
        let service = FakeLoginItemService()
        manager(service).launch()
        XCTAssertEqual(service.registerCalls, 1)
        manager(service).launch()
        XCTAssertEqual(service.registerCalls, 1, "enabled now, so nothing to do")
        service.status = .notRegistered  // for example after the app moved
        manager(service).launch()
        XCTAssertEqual(service.registerCalls, 2, "the system's status decides, not a remembered flag")
    }

    /// The first build set "loginItemConfigured" and then only registered once.
    /// Configured but not registered now most likely means the person
    /// removed it, so it is kept off.
    func testTheFirstBuildFlagWithNothingRegisteredIsTheOptOut() {
        defaults.set(true, forKey: "loginItemConfigured")
        let service = FakeLoginItemService()
        manager(service).launch()
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertTrue(defaults.bool(forKey: LoginItemManager.userDisabledKey))
        XCTAssertNil(defaults.object(forKey: "loginItemConfigured"), "migrated once, then gone")
    }

    func testTheFirstBuildFlagWithTheItemEnabledChangesNothing() {
        defaults.set(true, forKey: "loginItemConfigured")
        let service = FakeLoginItemService()
        service.status = .enabled
        manager(service).launch()
        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertFalse(defaults.bool(forKey: LoginItemManager.userDisabledKey))
        XCTAssertNil(defaults.object(forKey: "loginItemConfigured"))
    }

    func testAfterTheMigrationTheToggleTurnsItBackOnForGood() {
        defaults.set(true, forKey: "loginItemConfigured")
        let service = FakeLoginItemService()
        manager(service).launch()
        manager(service).setEnabled(true)
        XCTAssertEqual(service.status, .enabled)
        service.status = .notRegistered
        manager(service).launch()
        XCTAssertEqual(service.registerCalls, 2, "the old flag does not come back to switch it off again")
    }

    func testAFirstBuildFlagThatWasFalseIsJustRemoved() {
        defaults.set(false, forKey: "loginItemConfigured")
        let service = FakeLoginItemService()
        manager(service).launch()
        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertNil(defaults.object(forKey: "loginItemConfigured"))
    }

    func testApprovalStatesAreLeftToThePerson() {
        let service = FakeLoginItemService()
        service.status = .requiresApproval
        manager(service).launch()
        XCTAssertEqual(service.registerCalls, 0)
    }

    func testTurningItOffStaysOff() {
        let service = FakeLoginItemService()
        let manager = manager(service)
        manager.launch()
        manager.setEnabled(false)
        XCTAssertEqual(service.status, .notRegistered)
        self.manager(service).launch()
        XCTAssertEqual(service.registerCalls, 1, "the person's choice wins")
        XCTAssertTrue(defaults.bool(forKey: LoginItemManager.userDisabledKey))
    }

    func testTurningItBackOnClearsTheChoice() {
        let service = FakeLoginItemService()
        let manager = manager(service)
        manager.setEnabled(false)
        manager.setEnabled(true)
        XCTAssertEqual(service.status, .enabled)
        XCTAssertFalse(defaults.bool(forKey: LoginItemManager.userDisabledKey))
        service.status = .notRegistered
        self.manager(service).launch()
        XCTAssertEqual(service.registerCalls, 2)
    }

    func testAFailedRegistrationKeepsTheErrorAndRetries() {
        let service = FakeLoginItemService()
        service.failures = ["Operation not permitted"]
        manager(service).launch()
        XCTAssertEqual(manager(service).lastError, "Operation not permitted")
        manager(service).launch()
        XCTAssertEqual(service.registerCalls, 2)
        XCTAssertEqual(service.status, .enabled)
        XCTAssertNil(manager(service).lastError)
    }

    func testAFailedToggleKeepsTheErrorAndTheChoice() {
        let service = FakeLoginItemService()
        let manager = manager(service)
        manager.launch()
        service.failures = ["Needs approval"]
        manager.setEnabled(false)
        XCTAssertEqual(manager.lastError, "Needs approval")
        XCTAssertEqual(service.status, .enabled)
        XCTAssertFalse(defaults.bool(forKey: LoginItemManager.userDisabledKey), "not off until it worked")
    }

    /// Each named suite a test creates is written to ~/Library/Preferences
    /// by the preferences daemon and never removed, so the tests use an
    /// in-memory store instead. Scans every test source for one.
    func testNoTestCreatesANamedDefaultsSuite() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        let needle = "UserDefaults" + "(suiteName"
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(needle), "\(file.lastPathComponent) creates a named defaults suite")
        }
    }

    // MARK: moving from the app login item to the launchd job

    func manager(_ service: FakeLoginItemService, legacy: FakeLoginItemService) -> LoginItemManager {
        LoginItemManager(service: service, legacy: legacy, defaults: defaults)
    }

    /// Earlier builds registered the app itself as a login item. That item
    /// is removed once and the launchd job registered in its place.
    func testTheOldLoginItemIsReplacedByTheJob() {
        let job = FakeLoginItemService()
        let old = FakeLoginItemService()
        old.status = .enabled
        manager(job, legacy: old).launch()
        XCTAssertEqual(old.unregisterCalls, 1)
        XCTAssertEqual(old.status, .notRegistered)
        XCTAssertEqual(job.registerCalls, 1)
        XCTAssertEqual(job.status, .enabled)
        old.status = .enabled  // whatever the old item does later, it is not touched again
        manager(job, legacy: old).launch()
        XCTAssertEqual(old.unregisterCalls, 1, "once")
    }

    /// An old item awaiting approval was turned off in System Settings:
    /// that choice carries over, the job is not registered, and the status
    /// window says why. The old item is still removed.
    func testAnOldItemTurnedOffInSystemSettingsStaysOff() {
        let job = FakeLoginItemService()
        let old = FakeLoginItemService()
        old.status = .requiresApproval
        let manager = manager(job, legacy: old)
        manager.launch()
        XCTAssertEqual(old.unregisterCalls, 1)
        XCTAssertEqual(job.registerCalls, 0)
        XCTAssertTrue(defaults.bool(forKey: LoginItemManager.userDisabledKey))
        XCTAssertEqual(manager.note, "Start at login was turned off in System Settings")
        XCTAssertEqual(manager.readiness, .unavailable("Start at login was turned off in System Settings"))
        manager.setEnabled(true)
        XCTAssertEqual(job.status, .enabled)
        XCTAssertNil(manager.note, "turning it on answers the note")
        XCTAssertEqual(manager.readiness, .ready)
    }

    func testReadinessSaysWhyTheJobCannotRun() {
        let job = FakeLoginItemService()
        job.status = .enabled
        XCTAssertEqual(manager(job).readiness, .ready)
        job.status = .requiresApproval
        XCTAssertEqual(manager(job).readiness,
                       .unavailable("Start at login needs approval in System Settings, General, Login Items"))
        job.status = .notRegistered
        XCTAssertEqual(manager(job).readiness, .unavailable("the launchd job is not registered"))
        job.failures = ["Operation not permitted"]
        manager(job).launch()
        XCTAssertEqual(manager(job).readiness, .unavailable("the launchd job is not registered: Operation not permitted"))
        job.status = .enabled
        defaults.set(true, forKey: LoginItemManager.userDisabledKey)
        XCTAssertEqual(manager(job).readiness, .unavailable("Start at login is off"))
    }

    /// After the app is replaced, the new copy registers the job again
    /// (off, then on), keeping the person's choice: off stays off, and a job
    /// awaiting approval is left to System Settings.
    func testTheNewCopyRegistersTheJobAgain() {
        let job = FakeLoginItemService()
        job.status = .enabled
        XCTAssertEqual(manager(job).registerAgain(), .registered)
        XCTAssertEqual(job.unregisterCalls, 1)
        XCTAssertEqual(job.registerCalls, 1)

        let off = FakeLoginItemService()
        off.status = .notRegistered
        defaults.set(true, forKey: LoginItemManager.userDisabledKey)
        XCTAssertEqual(manager(off).registerAgain(), .leftOff("Start at login is off"))
        XCTAssertEqual(off.registerCalls, 0)
        defaults.removeObject(forKey: LoginItemManager.userDisabledKey)

        let waiting = FakeLoginItemService()
        waiting.status = .requiresApproval
        XCTAssertEqual(manager(waiting).registerAgain(),
                       .leftOff("Start at login needs approval in System Settings, General, Login Items"))
        XCTAssertEqual(waiting.unregisterCalls, 0)
        XCTAssertEqual(waiting.registerCalls, 0)
    }

    /// Start at login turned off before the move stays off after it.
    func testTurnedOffBeforeTheMoveStaysOff() {
        let job = FakeLoginItemService()
        let old = FakeLoginItemService()
        defaults.set(true, forKey: LoginItemManager.userDisabledKey)
        manager(job, legacy: old).launch()
        XCTAssertEqual(old.unregisterCalls, 0, "nothing registered to remove")
        XCTAssertEqual(job.registerCalls, 0)
    }

    /// The first build's opt-out reading looks at the old item, which is
    /// what that build registered.
    func testTheFirstBuildFlagReadsTheOldItem() {
        defaults.set(true, forKey: "loginItemConfigured")
        let job = FakeLoginItemService()
        let old = FakeLoginItemService()
        old.status = .enabled
        manager(job, legacy: old).launch()
        XCTAssertFalse(defaults.bool(forKey: LoginItemManager.userDisabledKey), "the old item was on")
        XCTAssertEqual(job.registerCalls, 1)
    }

    /// A registration that fails is an error, not a choice: the install
    /// script fails loudly on it.
    func testARegistrationErrorIsNotAnOptOut() {
        let job = FakeLoginItemService()
        job.failures = ["Operation not permitted"]
        XCTAssertEqual(manager(job).registerAgain(), .failed("Operation not permitted"))
    }

    /// Re-registering takes the job off first; when that fails (the job
    /// still enabled) nothing was re-registered, and that is an error the
    /// install script and the status window report.
    func testAFailedRemovalBeforeReRegisteringIsAnError() {
        let job = FakeLoginItemService()
        job.status = .enabled
        job.failures = ["Operation not permitted"]
        let manager = manager(job)
        XCTAssertEqual(manager.registerAgain(), .failed("Operation not permitted"))
        XCTAssertEqual(manager.lastError, "Operation not permitted")
        XCTAssertEqual(job.registerCalls, 0)
    }

    /// A failed job registration stays reported: nothing in the same
    /// launch clears it, and the old item (still the only working one) is
    /// kept.
    func testTheOldItemsRemovalKeepsARegistrationError() {
        let job = FakeLoginItemService()
        job.failures = ["Operation not permitted"]
        let old = FakeLoginItemService()
        old.status = .enabled
        let manager = manager(job, legacy: old)
        XCTAssertEqual(manager.registerAgain(), .failed("Operation not permitted"))
        XCTAssertEqual(old.status, .enabled, "the old item is kept while its replacement failed")
        XCTAssertEqual(manager.lastError, "Operation not permitted", "and the status window still shows the error")
    }

    /// Turning Start at login off ends the app, whichever copy runs:
    /// "off" means nothing runs. Only once the job is really removed.
    func testTurningItOffStopsTheApp() {
        let job = FakeLoginItemService()
        job.status = .enabled
        XCTAssertEqual(manager(job).setEnabled(false), .stopTheApp)
        XCTAssertEqual(manager(job).setEnabled(true), .keepRunning)
        job.failures = ["Operation not permitted"]
        XCTAssertEqual(manager(job).setEnabled(false), .keepRunning, "still registered, so the app stays")
    }

    /// Started by the old login item, removing that item can end this very
    /// process; so the move is recorded and the job registered first, and
    /// the old item removed last.
    func testTheOldItemIsRemovedLast() {
        let job = FakeLoginItemService()
        let old = FakeLoginItemService()
        old.status = .enabled
        var atRemoval: (moved: Bool, registered: Int)?
        old.onUnregister = {
            atRemoval = (self.defaults.bool(forKey: LoginItemManager.movedToJobKey), job.registerCalls)
        }
        manager(job, legacy: old).launch()
        XCTAssertEqual(atRemoval?.moved, true)
        XCTAssertEqual(atRemoval?.registered, 1)
    }

    /// The old item goes only once the job replacing it reads enabled: a
    /// failed (or pending) replacement keeps the only working item, keeps
    /// the error, and replaces it on a later launch.
    func testAFailedReplacementKeepsTheOldItem() {
        let job = FakeLoginItemService()
        job.failures = ["Operation not permitted"]
        let old = FakeLoginItemService()
        old.status = .enabled
        let first = manager(job, legacy: old)
        first.launch()
        XCTAssertEqual(old.unregisterCalls, 0)
        XCTAssertEqual(old.status, .enabled)
        XCTAssertEqual(first.lastError, "Operation not permitted")
        let waiting = FakeLoginItemService()
        waiting.status = .requiresApproval
        manager(waiting, legacy: old).launch()
        XCTAssertEqual(old.unregisterCalls, 0, "a job awaiting approval does not replace it yet")
        manager(job, legacy: old).launch()
        XCTAssertEqual(job.status, .enabled)
        XCTAssertEqual(old.unregisterCalls, 1)
        XCTAssertEqual(old.status, .notRegistered)
    }

    /// Ended (or failed) while removing the old item: the next launch
    /// removes it, and the job is not registered twice.
    func testARemovalCutShortIsFinishedNextLaunch() {
        let job = FakeLoginItemService()
        let old = FakeLoginItemService()
        old.status = .enabled
        old.failures = ["killed"]
        manager(job, legacy: old).launch()
        XCTAssertEqual(old.status, .enabled)
        manager(job, legacy: old).launch()
        XCTAssertEqual(old.unregisterCalls, 2)
        XCTAssertEqual(old.status, .notRegistered)
        XCTAssertEqual(job.registerCalls, 1)
        manager(job, legacy: old).launch()
        XCTAssertEqual(old.unregisterCalls, 2, "done")
    }

    /// A launchd job never registered reads as not found, not as not
    /// registered; it is registered all the same. Seen live on macOS 27.
    func testAJobNotYetFoundIsRegistered() {
        let job = FakeLoginItemService()
        job.status = .notFound
        manager(job, legacy: FakeLoginItemService()).launch()
        XCTAssertEqual(job.registerCalls, 1)
        XCTAssertEqual(job.status, .enabled)
        defaults.set(true, forKey: LoginItemManager.userDisabledKey)
        job.status = .notFound
        manager(job, legacy: FakeLoginItemService()).launch()
        XCTAssertEqual(job.registerCalls, 1, "turned off stays off")
    }

    /// Turning Start at login off ends the running agent while the job is
    /// removed, so the choice is saved before that, and put back if the
    /// removal fails.
    func testTheOffChoiceIsSavedBeforeTheJobIsRemoved() {
        let job = FakeLoginItemService()
        job.status = .enabled
        var savedAtRemoval: Bool?
        job.onUnregister = { savedAtRemoval = self.defaults.bool(forKey: LoginItemManager.userDisabledKey) }
        manager(job).setEnabled(false)
        XCTAssertEqual(savedAtRemoval, true)
        job.status = .enabled
        job.failures = ["Operation not permitted"]
        defaults.set(false, forKey: LoginItemManager.userDisabledKey)
        manager(job).setEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: LoginItemManager.userDisabledKey), "put back when it failed")
    }

    func testTheToggleActsOnTheJob() {
        let job = FakeLoginItemService()
        let old = FakeLoginItemService()
        let manager = manager(job, legacy: old)
        manager.launch()
        manager.setEnabled(false)
        XCTAssertEqual(job.status, .notRegistered)
        XCTAssertEqual(manager.status, .notRegistered)
        manager.setEnabled(true)
        XCTAssertEqual(job.status, .enabled)
        XCTAssertEqual(old.registerCalls, 0)
    }

    func testLoginItemErrorsAreMasked() {
        let service = FakeLoginItemService()
        service.failures = ["denied for alex+work@example.com"]
        manager(service).launch()
        XCTAssertEqual(manager(service).lastError, "denied for ale***@***.com")
    }
}
