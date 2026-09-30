import XCTest
@testable import UsageCore
@testable import UsageAgentCore

/// The container is anchored once at launch. When a later
/// poll finds another folder at its path, the agent stops polling and
/// writes nothing anywhere; the status window asks for a quit and reopen.
/// Nothing is migrated and nothing is relaunched.
final class ContainerReplacedTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func ok() -> Result<RunOutput, RunFailure> {
        .success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20)])))
    }

    /// Every file under `dir` with its bytes and inode.
    func contents(_ dir: URL) throws -> [String: (Data, Int)] {
        var out: [String: (Data, Int)] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(name)
            let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int ?? -1
            out[name] = (try Data(contentsOf: url), inode)
        }
        return out
    }

    func assertSame(_ a: [String: (Data, Int)], _ b: [String: (Data, Int)], _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(a.keys), Set(b.keys), message, file: file, line: line)
        for (name, value) in a {
            XCTAssertEqual(value.0, b[name]?.0, "\(message): \(name) bytes", file: file, line: line)
            XCTAssertEqual(value.1, b[name]?.1, "\(message): \(name) inode", file: file, line: line)
        }
    }

    func testAReplacedContainerStopsPollingAndAllWrites() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let runner = ScriptedRunner([ok()])
        let reloads = Counter()
        let agent = UsageAgent(directory: dir, runner: runner, reload: { reloads.increment() }, clock: { clock.stamp })
        let first = await agent.tick()
        XCTAssertFalse(first.containerChanged)
        let old = URL(fileURLWithPath: dir.path + ".old-\(UUID().uuidString)")
        XCTAssertEqual(rename(dir.path, old.path), 0)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let oldBefore = try contents(old)
        let reloadsBefore = reloads.count

        for _ in 0..<3 {
            clock.advance(60)
            let report = await agent.tick()
            XCTAssertTrue(report.containerChanged)
            XCTAssertEqual(report.error, UsageAgent.containerReplacedMessage)
        }
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let taken = await agent.takeRefreshRequest()
        XCTAssertFalse(taken, "a stopped agent answers no press")

        XCTAssertEqual(runner.calls, 1, "no poll after the change")
        XCTAssertEqual(reloads.count, reloadsBefore, "no reload after the change")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), [RefreshRequestStore.fileName],
                       "nothing written into the new folder but this test's press")
        assertSame(oldBefore, try contents(old), "nothing written into the old folder")
    }

    /// A replacement that cannot be opened (mode 000) stops
    /// the agent the same way; it does not go on writing into the old folder.
    func testAnUnreadableReplacementStopsTheAgentToo() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let runner = ScriptedRunner([ok()])
        let agent = UsageAgent(directory: dir, runner: runner, reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        let old = URL(fileURLWithPath: dir.path + ".old-\(UUID().uuidString)")
        XCTAssertEqual(rename(dir.path, old.path), 0)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(dir.path, 0), 0)
        defer { chmod(dir.path, 0o755) }
        let oldBefore = try contents(old)

        for _ in 0..<3 {
            clock.advance(60)
            let report = await agent.tick()
            XCTAssertTrue(report.containerChanged)
            XCTAssertEqual(report.error, UsageAgent.containerReplacedMessage)
        }
        XCTAssertEqual(runner.calls, 1, "no poll after the change")
        assertSame(oldBefore, try contents(old), "nothing written into the old folder")
        XCTAssertEqual(chmod(dir.path, 0o755), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [], "nor into the new one")
    }

    /// A path that cannot be checked (its parent unreadable) is not a
    /// replacement: the agent logs it once and keeps polling.
    func testAnUncheckablePathIsLoggedOnceAndPollingGoesOn() async throws {
        let parent = try makeTemporaryDirectory()
        let dir = parent.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let clock = ManualClock(start)
        let runner = ScriptedRunner([ok()])
        let agent = UsageAgent(directory: dir, runner: runner, reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        XCTAssertEqual(chmod(parent.path, 0), 0)
        for _ in 0..<3 {
            clock.advance(60)
            let report = await agent.tick()
            XCTAssertFalse(report.containerChanged)
        }
        XCTAssertEqual(chmod(parent.path, 0o755), 0)
        XCTAssertEqual(runner.calls, 4, "polling went on")
        let log = try String(contentsOf: dir.appendingPathComponent(SharedContainer.agentLogFileName), encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "container path could not be checked").count - 1, 1)
    }

    func testTheMessageAsksForAQuitAndReopen() {
        XCTAssertEqual(UsageAgent.containerReplacedMessage, "The data folder was replaced. Quit and reopen Usage Widget.")
    }

    /// The relaunch path is gone: no marker, no relaunch type, and the
    /// launch decision has only its lock and login inputs.
    func testNoRelaunchMarkerRemains() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var files: [URL] = []
        for folder in ["App", "Widget", "Packages/UsageKit/Sources"] {
            let found = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            XCTAssertFalse(found.isEmpty, folder)
            files += found
        }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for needle in ["after-container-change", "Relaunch", "afterContainerChange", "/usr/bin/open"] {
                XCTAssertFalse(text.contains(needle), "\(file.lastPathComponent) still has \(needle)")
            }
        }
        XCTAssertEqual(LaunchDecision.decide(lock: .heldElsewhere, loginLaunch: false), .handOverAndExit)
        XCTAssertEqual(LaunchDecision.decide(lock: .heldElsewhere, loginLaunch: true), .exitQuietly)
    }

    /// The press file is the widget's alone: the agent reads it and never
    /// writes it.
    func testTheAgentNeverWritesTheRefreshRequest() async throws {
        let dir = try makeTemporaryDirectory()
        let clock = ManualClock(start)
        let agent = UsageAgent(directory: dir, runner: ScriptedRunner([ok()]), reload: {}, clock: { clock.stamp })
        _ = await agent.tick()
        try RefreshRequestStore.request(in: dir, at: clock.now)
        let url = dir.appendingPathComponent(RefreshRequestStore.fileName)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        let bytes = try Data(contentsOf: url)
        let taken = await agent.takeRefreshRequest()
        XCTAssertTrue(taken)
        _ = await agent.tick(userRequested: true)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int, before)
        XCTAssertEqual(try Data(contentsOf: url), bytes)

        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/UsageAgentCore")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for call in ["RefreshRequestStore.request(", "RefreshRequestStore.write("] {
                XCTAssertFalse(text.contains(call), "\(file.lastPathComponent) calls \(call)")
            }
        }
    }
}
