import XCTest
import UsageCore
@testable import UsageAgentCore

final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var failures: [String] = []
    var registerCalls = 0
    var unregisterCalls = 0

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

    func testLoginItemErrorsAreMasked() {
        let service = FakeLoginItemService()
        service.failures = ["denied for alex+work@example.com"]
        manager(service).launch()
        XCTAssertEqual(manager(service).lastError, "denied for ale***@***.com")
    }
}
