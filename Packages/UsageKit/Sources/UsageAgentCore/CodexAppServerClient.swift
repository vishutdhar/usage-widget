import Foundation
import UsageCore

/// Reads Codex rate limits through the official CLI: `codex app-server`
/// over stdio, one handshake and one `account/rateLimits/read`, in its own
/// process group with the same output caps and kill logic as the cswap
/// runner.
public struct CodexAppServerClient: Sendable {
    public var paths: CodexPaths
    public var timeout: TimeInterval
    public var executable: URL?
    public static let arguments = ["app-server"]

    public init(paths: CodexPaths = CodexPaths(), timeout: TimeInterval = 20, executable: URL? = nil) {
        self.paths = paths
        self.timeout = timeout
        self.executable = executable
    }

    public func readRateLimits(now: @escaping @Sendable () -> Date = { Date() }) async -> Result<CodexReading, FetchFailure> {
        guard let binary = executable ?? paths.resolveBinary() else {
            return .failure(FetchFailure(reason: "codex not found"))
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: converse(executable: binary, now: now))
            }
        }
    }

    /// Blocking conversation with an app-server binary: `initialize`, the
    /// `initialized` notification, one `account/rateLimits/read`, then
    /// stdin is closed and the child reaped. Every line sent is built by
    /// `CodexRPC`, which refuses anything else.
    public func converse(executable: URL, now: () -> Date = { Date() }) -> Result<CodexReading, FetchFailure> {
        Reaper.sweep()
        var inPipe: [Int32] = [-1, -1]
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&inPipe) == 0 else { return fail("could not start: \(ProcessCswapRunner.errnoText())") }
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            for fd in inPipe + outPipe + errPipe where fd >= 0 { close(fd) }
            return fail("could not start: \(ProcessCswapRunner.errnoText())")
        }
        // Writing to a child that has gone must return an error, not kill the agent.
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)
        _ = fcntl(inPipe[1], F_SETFD, FD_CLOEXEC)
        var stdin = inPipe[1]
        var readers = PipeReaders(out: outPipe[0], err: errPipe[0])
        defer {
            readers.closeAll()
            if stdin >= 0 { close(stdin) }
        }

        let spawned = spawnInOwnGroup(executable: executable, arguments: Self.arguments, environment: environment(),
                                      stdin: inPipe[0], stdout: outPipe[1], stderr: errPipe[1])
        close(inPipe[0])
        close(outPipe[1])
        close(errPipe[1])
        let pid: pid_t
        switch spawned {
        case .failure(.launchFailed(let detail)): return fail("could not start: \(detail)")
        case .failure: return fail("could not start")
        case .success(let child): pid = child
        }

        var session = Session(pid: pid, deadline: ProcessCswapRunner.uptime() + timeout, timeout: timeout)
        let outcome: Result<CodexReading, FetchFailure>
        do {
            try session.send(CodexRPC.request(id: 1, method: "initialize",
                                              params: ["clientInfo": ["name": "usage-widget", "version": "1.0"]]),
                             to: stdin)
            _ = try session.awaitResult(id: 1, readers: &readers)
            try session.send(CodexRPC.notification(method: "initialized"), to: stdin)
            try session.send(CodexRPC.request(id: 2, method: "account/rateLimits/read"), to: stdin)
            let result = try session.awaitResult(id: 2, readers: &readers)
            if let reading = CodexAppServerParser.reading(fromResult: result, fetchedAt: now()) {
                outcome = .success(reading)
            } else {
                // A reply with no usable window is a failed call, not a reading.
                outcome = .failure(FetchFailure(reason: "codex app-server: no limits in reply"))
            }
        } catch let failure as FetchFailure {
            outcome = .failure(failure)
        } catch {
            outcome = fail("could not be asked")
        }

        // Done: close stdin so the server can leave, then make sure it has.
        close(stdin)
        stdin = -1
        session.finish(readers: &readers)
        return outcome
    }

    private func fail(_ detail: String) -> Result<CodexReading, FetchFailure> {
        .failure(FetchFailure(reason: CswapInterpreter.shorten("codex app-server \(detail)")))
    }

    /// The app's environment with Homebrew and the other install
    /// directories in front of PATH: the CLI is a node script.
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (paths.searchDirectories.map(\.path) + [inherited]).joined(separator: ":")
        return env
    }
}

/// One running app-server: line framing, deadlines and caps.
private struct Session {
    let pid: pid_t
    let deadline: TimeInterval
    let timeout: TimeInterval
    var buffer = Data()
    var total = 0
    var status: Int32?

    func failure(_ detail: String) -> FetchFailure {
        FetchFailure(reason: CswapInterpreter.shorten("codex app-server \(detail)"))
    }

    func send(_ line: Data, to fd: Int32) throws {
        var offset = 0
        while offset < line.count {
            let n = line.withUnsafeBytes { write(fd, $0.baseAddress! + offset, line.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                throw failure("exited before answering")
            }
            offset += n
        }
    }

    /// Reads lines until the reply to `id` arrives. Notifications, log
    /// lines and anything else are skipped.
    mutating func awaitResult(id: Int, readers: inout PipeReaders) throws -> [String: Any] {
        while true {
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      message["id"] as? Int == id, message["method"] == nil
                else { continue }
                if let result = message["result"] as? [String: Any] { return result }
                if let error = message["error"] as? [String: Any] {
                    throw FetchFailure(reason: CswapInterpreter.shorten(
                        "codex app-server: \((error["message"] as? String) ?? "error")"))
                }
                throw failure("reply could not be read")
            }
            if status == nil, let reaped = ProcessCswapRunner.reap(pid) { status = reaped }
            if readers.stdoutClosed, let status {
                throw failure("exited before answering (code \(ProcessCswapRunner.exitCode(status)))")
            }
            // A server that closed its output can no longer answer, but it
            // is only waited for until the same deadline, without blocking;
            // `finish` then ends it.
            if ProcessCswapRunner.uptime() >= deadline {
                throw failure(readers.stdoutClosed ? "closed its output without answering"
                                                   : "did not answer within \(Int(timeout)) s")
            }
            switch readers.readAvailable(waitMilliseconds: 50) {
            case .stdout(let chunk):
                total += chunk.count
                guard total <= ProcessCswapRunner.stdoutCap else { throw failure("output too large") }
                buffer.append(chunk)
            case .stderr, .none:
                break
            }
        }
    }

    /// Gives the server a moment to exit on its own after stdin closes,
    /// then signals its whole group.
    mutating func finish(readers: inout PipeReaders) {
        readers.closeAll()
        let graceEnd = ProcessCswapRunner.uptime() + ProcessCswapRunner.terminateGrace
        while status == nil, ProcessCswapRunner.uptime() < graceEnd {
            if let reaped = ProcessCswapRunner.reap(pid) { status = reaped } else { usleep(20_000) }
        }
        ProcessCswapRunner.terminateGroup(pid, reaped: status != nil)
    }
}
