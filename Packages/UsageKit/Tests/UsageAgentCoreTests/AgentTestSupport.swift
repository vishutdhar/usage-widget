import Foundation
import UsageCore
@testable import UsageAgentCore

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("usageagent-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An executable shell script in a fresh temporary directory.
func makeScript(_ body: String) throws -> URL {
    let url = try makeTemporaryDirectory().appendingPathComponent("fake-cswap")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// A fake cswap at `home/.local/bin/cswap`, the first place the locator
/// looks, so a `ProcessCswapRunner` given that home runs it. Returns the home.
func makeCswapHome(_ body: String) throws -> URL {
    let home = try makeTemporaryDirectory()
    let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let url = bin.appendingPathComponent("cswap")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return home
}

/// cswap list --json output with one account per (id, active, fiveHourPct),
/// each measured at `fetchedAt`.
func listJSON(_ accounts: [(String, Bool, Double)], schema: Int = 1, fetchedAt: String = "2026-09-27T10:00:00Z") -> Data {
    let rows = accounts.map { id, active, pct in
        """
        {"number": \(id), "email": "user\(id)@example.com", "active": \(active), "usageStatus": "ok",
         "usage": {"fiveHour": {"pct": \(pct), "resetsAt": "2026-09-27T14:00:00+00:00"},
                   "sevenDay": {"pct": 50.0, "resetsAt": "2026-10-01T00:00:00+00:00", "expectedPct": 40.0, "aheadOfPace": false}},
         "usageFetchedAt": "\(fetchedAt)"}
        """
    }
    return Data("{\"schemaVersion\": \(schema), \"accounts\": [\(rows.joined(separator: ","))]}".utf8)
}

/// A runner that replays scripted results, one per call.
final class ScriptedRunner: CswapRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<RunOutput, RunFailure>]

    init(_ results: [Result<RunOutput, RunFailure>]) {
        self.results = results
    }

    private var count = 0
    private var flags: [Bool] = []
    /// How many times cswap was run.
    var calls: Int { lock.withLock { count } }
    /// Whether each run asked for a fresh list, in order.
    var freshFlags: [Bool] { lock.withLock { flags } }

    func runList(fresh: Bool) async -> Result<RunOutput, RunFailure> {
        lock.withLock {
            count += 1
            flags.append(fresh)
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var elapsed: TimeInterval = 0
    init(_ start: Date) { current = start }
    func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; elapsed += seconds; lock.unlock() }
    /// Sets the wall clock without moving the continuous one, as a person
    /// or a time sync would.
    func setWall(_ date: Date) { lock.lock(); current = date; lock.unlock() }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    /// Wall and continuous time moving together, on one boot.
    var stamp: SchedulerClock {
        lock.lock(); defer { lock.unlock() }
        return SchedulerClock(wall: current, continuous: 1_000_000_000_000 + UInt64(elapsed * 1e9), boot: "test")
    }
}

func fixedClock(_ date: Date) -> @Sendable () -> SchedulerClock {
    { SchedulerClock(wall: date, continuous: 1, boot: "test") }
}

struct IndexMissing: Error, CustomStringConvertible {
    let index: Int
    let count: Int
    var description: String { "no element \(index) in \(count) elements" }
}

extension Array {
    /// A checked index, so a wrong result fails the test instead of trapping.
    subscript(at index: Int) -> Element {
        get throws {
            guard indices.contains(index) else { throw IndexMissing(index: index, count: count) }
            return self[index]
        }
    }
}
