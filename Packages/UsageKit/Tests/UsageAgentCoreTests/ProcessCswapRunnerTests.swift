import XCTest
@testable import UsageAgentCore

final class ProcessCswapRunnerTests: XCTestCase {
    func testCapturesStdoutAndExitCode() throws {
        let script = try makeScript(#"echo "args:$*"; echo "warn" >&2; exit 0"#)
        let output = try ProcessCswapRunner().run(executable: script).get()
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "args:list --json\n")
        XCTAssertEqual(String(decoding: output.stderr, as: UTF8.self), "warn\n")
    }

    func testAnOrdinaryRunRaisesNoHelperWarning() throws {
        let warnings = WarningRecorder()
        let output = try ProcessCswapRunner(warn: { category, _ in warnings.record(category) }).run(executable: try makeScript("echo '{}'")).get()
        XCTAssertFalse(output.leftHelper)
        XCTAssertEqual(warnings.messages, [])
    }

    func testNonZeroExitIsAnOutputNotAFailure() throws {
        let script = try makeScript("echo '{}'; exit 3")
        XCTAssertEqual(try ProcessCswapRunner().run(executable: script).get().exitCode, 3)
    }

    func testLargeOutputDoesNotDeadlock() throws {
        // Well past a pipe buffer (64 KB): a runner that waits for exit before
        // reading a pipe would hang here.
        let script = try makeScript("head -c 400000 /dev/zero | tr '\\\\0' 'a'")
        let output = try ProcessCswapRunner(timeout: 10).run(executable: script).get()
        XCTAssertEqual(output.stdout.count, 400_000)
    }

    func testTimeoutKillsTheProcess() throws {
        let script = try makeScript("sleep 30")
        let start = Date()
        let result = ProcessCswapRunner(timeout: 1).run(executable: script)
        XCTAssertEqual(result, .failure(.timedOut(1)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testTimeoutAlsoKillsAProcessThatIgnoresTerminate() throws {
        let script = try makeScript("trap '' TERM; sleep 30")
        let start = Date()
        XCTAssertEqual(ProcessCswapRunner(timeout: 1).run(executable: script), .failure(.timedOut(1)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    /// cswap may run helpers of its own. On a timeout the whole process
    /// group goes, not just cswap: here the script ignores TERM and leaves a
    /// backgrounded sleep that would otherwise outlive it.
    func testTimeoutKillsTheWholeProcessGroup() throws {
        let dir = try makeTemporaryDirectory()
        let pidFile = dir.appendingPathComponent("bg.pid")
        let script = try makeScript("trap '' TERM; sleep 30 & echo $! > '\(pidFile.path)'; sleep 30")
        XCTAssertEqual(ProcessCswapRunner(timeout: 1).run(executable: script), .failure(.timedOut(1)))
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(text))
        XCTAssertTrue(waitUntilGone(pid, within: 5), "the backgrounded sleep \(pid) survived the timeout")
    }

    func testAChildThatLeavesAHelperHoldingTheOutputStillReturns() throws {
        let dir = try makeTemporaryDirectory()
        let pidFile = dir.appendingPathComponent("helper.pid")
        let script = try makeScript("sleep 30 & echo $! > '\(pidFile.path)'; echo done")
        let start = Date()
        let warnings = WarningRecorder()
        let runner = ProcessCswapRunner(timeout: 20, warn: { category, _ in warnings.record(category) })
        let output = try runner.run(executable: script).get()
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "done\n")
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10, "a helper holding the pipe must not stall the poll")
        XCTAssertTrue(output.leftHelper)
        XCTAssertEqual(warnings.messages, ["cswap left a helper holding its output"])
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(pid_t(text))
        XCTAssertTrue(waitUntilGone(pid, within: 5), "the helper \(pid) was left running")
    }

    func testStdoutOverTheCapIsRefused() throws {
        let script = try makeScript("head -c 3000000 /dev/zero | tr '\\0' 'a'")
        XCTAssertEqual(ProcessCswapRunner(timeout: 20).run(executable: script), .failure(.outputTooLarge))
        XCTAssertEqual(ProcessCswapRunner.stdoutCap, 2 * 1024 * 1024)
    }

    func testOnlyTheTailOfStderrIsKept() throws {
        let script = try makeScript("head -c 200000 /dev/zero | tr '\\0' 'x' >&2; printf END >&2; echo '{}'")
        let output = try ProcessCswapRunner(timeout: 20).run(executable: script).get()
        XCTAssertEqual(output.stderr.count, ProcessCswapRunner.stderrCap)
        XCTAssertEqual(ProcessCswapRunner.stderrCap, 64 * 1024)
        XCTAssertTrue(String(decoding: output.stderr, as: UTF8.self).hasSuffix("xxEND"))
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "{}\n")
    }

    /// A child that moves itself into another process group escapes a
    /// group signal. It must still be killed, and a runner waiting on it
    /// must not deadlock while it is blocked writing to a full pipe.
    func testAChildThatLeavesTheGroupIsStillKilledOnOverflow() throws {
        let dir = try makeTemporaryDirectory()
        let pidFile = dir.appendingPathComponent("leader.pid")
        let script = try makeScript("""
            exec /usr/bin/perl -e 'open(F, ">\(pidFile.path)"); print F $$; close(F); setpgrp(0, getpgrp(getppid())) or die; print "a" x 3000000'
            """)
        let result = try runWithDeadline(ProcessCswapRunner(timeout: 20), script: script, deadline: 10, pidFile: pidFile)
        XCTAssertEqual(result, .failure(.outputTooLarge))
    }

    func testAChildThatLeavesTheGroupIsStillKilledOnTimeout() throws {
        let dir = try makeTemporaryDirectory()
        let pidFile = dir.appendingPathComponent("leader.pid")
        let script = try makeScript("""
            exec /usr/bin/perl -e 'open(F, ">\(pidFile.path)"); print F $$; close(F); $SIG{TERM} = "IGNORE"; setpgrp(0, getpgrp(getppid())) or die; sleep 30'
            """)
        let result = try runWithDeadline(ProcessCswapRunner(timeout: 1), script: script, deadline: 10, pidFile: pidFile)
        XCTAssertEqual(result, .failure(.timedOut(1)))
    }

    /// Runs on another thread; past `deadline` the test fails and kills the
    /// child itself so a deadlocked runner cannot hang the suite.
    func runWithDeadline(_ runner: ProcessCswapRunner, script: URL, deadline: TimeInterval, pidFile: URL) throws
        -> Result<RunOutput, RunFailure>?
    {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.set(runner.run(executable: script))
            done.signal()
        }
        if done.wait(timeout: .now() + deadline) == .timedOut {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text) {
                kill(pid, SIGKILL)
            }
            done.wait()
            XCTFail("the runner was still stuck after \(deadline) s")
        }
        return box.value
    }

    func waitUntilGone(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            usleep(50_000)
        }
        kill(pid, SIGKILL)  // do not leave it behind if the assertion fails
        return false
    }

    func testUnlaunchableFileIsALaunchFailure() throws {
        let dir = try makeTemporaryDirectory()
        let notExecutable = dir.appendingPathComponent("plain")
        try Data("x".utf8).write(to: notExecutable)
        guard case .failure(.launchFailed) = ProcessCswapRunner().run(executable: notExecutable) else {
            return XCTFail("expected a launch failure")
        }
    }

    func testRunListReportsNotFoundWhenNothingIsInstalled() async throws {
        let runner = ProcessCswapRunner(locator: CswapLocator(home: try makeTemporaryDirectory()))
        // The fixed system paths may hold a real cswap on a developer machine;
        // only assert when none of them exist.
        guard runner.locator.resolve() == nil else { throw XCTSkip("cswap is installed at a system path") }
        let result = await runner.runList(fresh: false)
        XCTAssertEqual(result, .failure(.notFound))
    }

    /// A press asks cswap to measure every account now (`--fresh`); a
    /// background poll takes its cached list. The fake cswap prints each
    /// argument on its own line, so the exact argument list is pinned.
    func testAFreshListAddsTheFreshOption() async throws {
        let home = try makeCswapHome(#"printf '%s\n' "$@""#)
        let runner = ProcessCswapRunner(locator: CswapLocator(home: home))
        let fresh = try await runner.runList(fresh: true).get()
        XCTAssertEqual(String(decoding: fresh.stdout, as: UTF8.self), "list\n--json\n--fresh\n")
        let cached = try await runner.runList(fresh: false).get()
        XCTAssertEqual(String(decoding: cached.stdout, as: UTF8.self), "list\n--json\n")
    }

    func testChildSeesTheInstallDirectoriesOnItsPath() throws {
        let script = try makeScript(#"echo "$PATH""#)
        let home = URL(fileURLWithPath: "/Users/someone")
        let output = try ProcessCswapRunner(locator: CswapLocator(home: home)).run(executable: script).get()
        let path = String(decoding: output.stdout, as: UTF8.self)
        XCTAssertTrue(path.hasPrefix("/Users/someone/.local/bin:/opt/homebrew/bin:/usr/local/bin:"), path)
    }
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<RunOutput, RunFailure>?
    func set(_ value: Result<RunOutput, RunFailure>) { lock.withLock { stored = value } }
    var value: Result<RunOutput, RunFailure>? { lock.withLock { stored } }
}

final class WarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ message: String) { lock.withLock { stored.append(message) } }
    var messages: [String] { lock.withLock { stored } }
}
