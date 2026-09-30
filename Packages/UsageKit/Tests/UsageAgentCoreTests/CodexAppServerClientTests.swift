import XCTest
import UsageCore
@testable import UsageAgentCore

/// A stand-in `codex app-server`: it logs every method it receives and
/// answers from the script's mode.
func fakeAppServer(mode: String, log: URL) throws -> URL {
    let dir = try makeTemporaryDirectory()
    let python = dir.appendingPathComponent("fake.py")
    let result = """
    {"accountId": "acct_example", "rateLimits": {"limitId": "codex", "planType": "pro",
     "primary": {"usedPercent": 45, "windowDurationMins": 10080, "resetsAt": 1791072000}, "secondary": null},
     "rateLimitResetCredits": {"availableCount": 2, "credits": null}}
    """
    try Data("""
    import json, os, sys, time
    mode = sys.argv[1]
    log = open(sys.argv[2], "a")
    log.write("ARGS " + " ".join(sys.argv[3:]) + "\\n")
    log.write("PATH " + os.environ.get("PATH", "") + "\\n")
    log.write("PID " + str(os.getpid()) + "\\n")
    log.flush()
    if mode == "exit":
        sys.exit(3)
    if mode == "closeout":
        # Closes its output, then stays alive with stdin open.
        os.close(1)
        time.sleep(60)
    if mode == "closeout-stderr":
        # Closes its output, shrugs off TERM and broken pipes, and keeps
        # writing to stderr.
        import signal
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGPIPE, signal.SIG_IGN)
        os.close(1)
        chunk = b"x" * 65536
        while True:
            try:
                os.write(2, chunk)
            except OSError:
                time.sleep(0.01)
    print("not json, a log line", flush=True)
    for line in sys.stdin:
        msg = json.loads(line)
        log.write("METHOD " + msg.get("method", "") + "\\n"); log.flush()
        if mode == "hang":
            time.sleep(60)
        if msg.get("method") == "initialize":
            print(json.dumps({"id": msg["id"], "result": {"codexHome": "/x", "platformFamily": "unix",
                                                         "platformOs": "macos", "userAgent": "fake"}}), flush=True)
        elif msg.get("method") == "account/rateLimits/read":
            print(json.dumps({"method": "account/rateLimits/updated", "params": {}}), flush=True)
            if mode == "emptylimits":
                print(json.dumps({"id": msg["id"], "result": {"rateLimits": {}, "rateLimitResetCredits": {"availableCount": 2}}}), flush=True)
            elif mode == "rpcerror":
                print(json.dumps({"id": msg["id"], "error": {"code": -32600, "message": "not logged in as sam@example.com"}}), flush=True)
            else:
                print(json.dumps({"id": msg["id"], "result": json.loads('''\(result)''')}), flush=True)
    """.utf8).write(to: python)
    return try makeScript(#"exec /usr/bin/python3 "\#(python.path)" \#(mode) "\#(log.path)" "$@""#)
}

final class CodexAppServerClientTests: XCTestCase {
    func logLines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Runs a conversation on another thread, so a client that blocks fails
    /// the test instead of hanging the suite.
    func converseWithin(_ limit: TimeInterval, mode: String, timeout: TimeInterval = 1)
        throws -> (result: Result<CodexReading, FetchFailure>?, seconds: TimeInterval, leftRunning: Bool) {
        let log = try makeTemporaryDirectory().appendingPathComponent("log")
        let server = try fakeAppServer(mode: mode, log: log)
        let done = expectation(description: "the call returns")
        let box = CodexResultBox()
        let started = Date()
        DispatchQueue.global().async {
            box.set(CodexAppServerClient(timeout: timeout).converse(executable: server))
            done.fulfill()
        }
        wait(for: [done], timeout: limit)
        let seconds = Date().timeIntervalSince(started)
        // A client that hung leaves the fake alive; end it so nothing leaks.
        var leftRunning = false
        for line in logLines(log) where line.hasPrefix("PID ") {
            if let pid = pid_t(line.dropFirst(4)) {
                leftRunning = leftRunning || kill(pid, 0) == 0
                kill(pid, SIGKILL)
            }
        }
        return (box.get(), seconds, leftRunning)
    }

    /// Closed output while the process lives on: the client never waits on
    /// it without a deadline, and the whole poll ends within the timeout
    /// plus the grace periods.
    func testAServerThatClosesItsOutputAndStaysIsCutOff() throws {
        let (result, seconds, leftRunning) = try converseWithin(15, mode: "closeout")
        XCTAssertLessThan(seconds, 1 + 3 * ProcessCswapRunner.terminateGrace + 1)
        XCTAssertFalse(leftRunning)
        guard case .failure(let failure)? = result else { return XCTFail("expected a failure, got \(String(describing: result))") }
        XCTAssertEqual(failure.reason, "codex app-server closed its output without answering")
    }

    func testAServerThatIgnoresTermAndFloodsStderrIsKilled() throws {
        let (result, seconds, leftRunning) = try converseWithin(15, mode: "closeout-stderr")
        XCTAssertLessThan(seconds, 1 + 3 * ProcessCswapRunner.terminateGrace + 1)
        XCTAssertFalse(leftRunning, "killed, not left flooding a closed pipe")
        guard case .failure(let failure)? = result else { return XCTFail("expected a failure, got \(String(describing: result))") }
        XCTAssertEqual(failure.reason, "codex app-server closed its output without answering")
    }

    func testTheHandshakeAndTheReadGiveAReading() throws {
        let log = try makeTemporaryDirectory().appendingPathComponent("log.txt")
        let fetched = ISODate.parse("2026-09-27T14:05:00Z")!
        let reading = try CodexAppServerClient(paths: CodexPaths(home: URL(fileURLWithPath: "/Users/someone")), timeout: 20)
            .converse(executable: try fakeAppServer(mode: "ok", log: log), now: { fetched }).get()
        XCTAssertEqual(reading.source, .appServer)
        XCTAssertEqual(reading.measuredAt, fetched)
        XCTAssertEqual(reading.resetCreditsAvailable, 2)
        XCTAssertEqual(reading.planType, "pro")
        XCTAssertEqual(reading.windows.map(\.name), ["Weekly"])
        XCTAssertEqual(reading.windows.map(\.usedPct), [45])
        let lines = logLines(log)
        XCTAssertEqual(lines.filter { $0.hasPrefix("METHOD ") },
                       ["METHOD initialize", "METHOD initialized", "METHOD account/rateLimits/read"],
                       "the handshake and the one read, nothing else")
        XCTAssertTrue(lines.contains("ARGS app-server"))
        let path = try XCTUnwrap(lines.first { $0.hasPrefix("PATH ") })
        XCTAssertTrue(path.hasPrefix("PATH /opt/homebrew/bin:"), path)
    }

    func testAnRPCErrorBecomesAMaskedReason() throws {
        let log = try makeTemporaryDirectory().appendingPathComponent("log.txt")
        let result = CodexAppServerClient().converse(executable: try fakeAppServer(mode: "rpcerror", log: log))
        XCTAssertEqual(result, .failure(FetchFailure(reason: "codex app-server: not logged in as sam***@***.com")))
    }

    /// A reply without limits is a failed call, not a reading with none.
    func testAReplyWithoutLimitsIsAFailure() throws {
        let result = CodexAppServerClient().converse(executable: try fakeAppServer(mode: "emptylimits",
                                                     log: try makeTemporaryDirectory().appendingPathComponent("log")))
        guard case .failure(let failure) = result else { return XCTFail("expected a failure, got \(result)") }
        XCTAssertEqual(failure.reason, "codex app-server: no limits in reply")
    }

    func testASilentServerTimesOut() throws {
        let log = try makeTemporaryDirectory().appendingPathComponent("log.txt")
        let start = Date()
        let result = CodexAppServerClient(timeout: 1).converse(executable: try fakeAppServer(mode: "hang", log: log))
        XCTAssertEqual(result, .failure(FetchFailure(reason: "codex app-server did not answer within 1 s")))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testAServerThatQuitsEarlyIsAFailure() throws {
        let log = try makeTemporaryDirectory().appendingPathComponent("log.txt")
        let result = CodexAppServerClient().converse(executable: try fakeAppServer(mode: "exit", log: log))
        XCTAssertEqual(result, .failure(FetchFailure(reason: "codex app-server exited before answering (code 3)")))
    }

    func testNoBinaryIsReported() async throws {
        let client = CodexAppServerClient(paths: CodexPaths(home: try makeTemporaryDirectory(), systemDirectories: []))
        XCTAssertNil(client.paths.resolveBinary())
        let result = await client.readRateLimits()
        XCTAssertEqual(result, .failure(FetchFailure(reason: "codex not found")))
    }
}

final class CodexResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<CodexReading, FetchFailure>?
    func set(_ result: Result<CodexReading, FetchFailure>) { lock.withLock { value = result } }
    func get() -> Result<CodexReading, FetchFailure>? { lock.withLock { value } }
}

/// Children killed but not yet exited are retried later, never waited on.
final class ReaperTests: XCTestCase {
    func spawnSleeper() throws -> pid_t {
        var null = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&null), 0)
        defer { close(null[0]); close(null[1]) }
        guard case .success(let pid) = spawnInOwnGroup(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                                       environment: [:], stdin: nil, stdout: null[1], stderr: null[1])
        else { throw XCTSkip("could not start /bin/sleep") }
        return pid
    }

    func testAnAdoptedChildIsReapedOnceItExits() throws {
        let pid = try spawnSleeper()
        let before = Reaper.count
        Reaper.adopt(pid)
        Reaper.sweep()
        XCTAssertEqual(Reaper.count, before + 1, "still running, still pending")
        kill(pid, SIGKILL)
        let end = Date().addingTimeInterval(3)
        while Reaper.count > before, Date() < end {
            Reaper.sweep()
            usleep(20_000)
        }
        XCTAssertEqual(Reaper.count, before, "reaped by a later sweep")
        XCTAssertEqual(waitpid(pid, nil, WNOHANG), -1, "nothing left to wait for")
    }

    func testAKilledChildIsReapedWithinTheGrace() throws {
        let pid = try spawnSleeper()
        let before = Reaper.count
        kill(pid, SIGKILL)
        let started = Date()
        ProcessCswapRunner.reapAfterKill(pid)
        XCTAssertLessThan(Date().timeIntervalSince(started), ProcessCswapRunner.killGrace + 0.5)
        XCTAssertEqual(Reaper.count, before, "reaped directly, not adopted")
    }
}
