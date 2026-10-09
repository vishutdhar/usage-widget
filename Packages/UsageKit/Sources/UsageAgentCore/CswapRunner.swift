import Foundation

public struct RunOutput: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    /// cswap exited but something it started still held its output.
    public var leftHelper = false

    public init(exitCode: Int32, stdout: Data, stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum RunFailure: Error, Equatable, Sendable {
    case notFound
    case launchFailed(String)
    case timedOut(TimeInterval)
    case outputTooLarge
}

public protocol CswapRunning: Sendable {
    /// One `cswap list --json`. With `fresh`, `cswap list --json --fresh`:
    /// a press's run, which re-measures every account now.
    func runList(fresh: Bool) async -> Result<RunOutput, RunFailure>
}

/// Runs `cswap list --json` (with `--fresh` for a press) as a child process.
///
/// The child is spawned as the leader of its own process group, so a
/// timeout or an oversized reply signals everything cswap started, not just
/// cswap. Output is streamed through pipes with caps: stdout past
/// `stdoutCap` is refused, and only the last `stderrCap` bytes of stderr are
/// kept. A helper left holding the pipes after cswap exits gets a short
/// grace, then the group is killed so the poll never stalls.
public struct ProcessCswapRunner: CswapRunning {
    public var locator: CswapLocator
    public var timeout: TimeInterval
    /// A background poll: cswap serves an account's cached numbers while
    /// they are younger than its serve time (3 to 10 minutes).
    public static let arguments = ["list", "--json"]
    /// A press: cswap re-measures every account now, except those it holds
    /// back (quarantined, backing off after a 429, or claimed), which it
    /// serves as they are.
    public static let freshArguments = ["list", "--json", "--fresh"]
    /// A real reading is a few kilobytes; anything past this is not one.
    public static let stdoutCap = 2 * 1024 * 1024
    /// Only the end of stderr is kept, where a traceback's message is.
    public static let stderrCap = 64 * 1024
    /// How long the group gets to exit after SIGTERM before SIGKILL.
    static let terminateGrace: TimeInterval = 2
    /// How long output may keep flowing after cswap itself has exited.
    static let drainGrace: TimeInterval = 2

    /// Called with a fixed category, safe to log publicly, and a detail
    /// that belongs in a private log.
    public var warn: @Sendable (_ category: String, _ detail: String) -> Void
    public static let helperWarning = "cswap left a helper holding its output"

    public init(locator: CswapLocator = CswapLocator(), timeout: TimeInterval = 50,
                warn: @escaping @Sendable (_ category: String, _ detail: String) -> Void = { _, _ in }) {
        self.locator = locator
        self.timeout = timeout
        self.warn = warn
    }

    public func runList(fresh: Bool) async -> Result<RunOutput, RunFailure> {
        guard let executable = locator.resolve() else { return .failure(.notFound) }
        let arguments = fresh ? Self.freshArguments : Self.arguments
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(executable: executable, arguments: arguments))
            }
        }
    }

    /// Blocking run of `executable` with `arguments`.
    public func run(executable: URL, arguments: [String] = ProcessCswapRunner.arguments) -> Result<RunOutput, RunFailure> {
        Reaper.sweep()
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return .failure(.launchFailed(Self.errnoText())) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return .failure(.launchFailed(Self.errnoText()))
        }
        var readers = PipeReaders(out: outPipe[0], err: errPipe[0])
        defer { readers.closeAll() }

        let spawned = spawnInOwnGroup(executable: executable, arguments: arguments, environment: environment(),
                                      stdin: nil, stdout: outPipe[1], stderr: errPipe[1])
        close(outPipe[1])
        close(errPipe[1])
        let pid: pid_t
        switch spawned {
        case .failure(let failure): return .failure(failure)
        case .success(let child): pid = child
        }

        var stdout = Data()
        var stderr = Data()
        var leftHelper = false
        var status: Int32?
        var exitedAt: TimeInterval?
        // Monotonic time: a wall clock change must not stretch or cut a timeout.
        let deadline = Self.uptime() + timeout

        while true {
            if status == nil, let reaped = Self.reap(pid) {
                status = reaped
                exitedAt = Self.uptime()
            }
            if status != nil, readers.allClosed { break }
            if let exitedAt, Self.uptime() - exitedAt > Self.drainGrace {
                // cswap has exited but something it started still holds the
                // pipes. macOS offers no process tree guarantee for helpers
                // that left the group (setsid); the group is killed and the
                // poll moves on.
                kill(-pid, SIGKILL)
                leftHelper = true
                warn(Self.helperWarning, "cswap pid \(pid) exited; its output was still open \(Self.drainGrace) s later")
                break
            }
            if Self.uptime() >= deadline {
                readers.closeAll()  // a writer blocked on a full pipe gets EPIPE instead
                Self.terminateGroup(pid, reaped: status != nil)
                return .failure(.timedOut(timeout))
            }
            switch readers.readAvailable(waitMilliseconds: 50) {
            case .none:
                break
            case .stdout(let chunk):
                stdout.append(chunk)
                if stdout.count > Self.stdoutCap {
                    // Closing first is belt and braces: the direct SIGKILL
                    // already frees a writer blocked on the full pipe.
                    readers.closeAll()
                    Self.signal(pid, SIGKILL, reaped: status != nil)
                    if status == nil { Self.reapAfterKill(pid) }
                    return .failure(.outputTooLarge)
                }
            case .stderr(let chunk):
                stderr.append(chunk)
                if stderr.count > Self.stderrCap { stderr.removeFirst(stderr.count - Self.stderrCap) }
            }
        }
        var output = RunOutput(exitCode: Self.exitCode(status ?? 0), stdout: stdout, stderr: stderr)
        output.leftHelper = leftHelper
        return .success(output)
    }

    /// SIGTERM to the group, a grace period for the leader to exit, then
    /// SIGKILL to whatever is left of the group.
    static func terminateGroup(_ pid: pid_t, reaped: Bool) {
        signal(pid, SIGTERM, reaped: reaped)
        var gone = reaped
        let graceEnd = uptime() + terminateGrace
        while !gone, uptime() < graceEnd {
            if reap(pid) != nil { gone = true } else { usleep(20_000) }
        }
        signal(pid, SIGKILL, reaped: gone)
        if !gone { reapAfterKill(pid) }
    }

    /// How long a killed child gets to be reaped before it is left for
    /// later polls.
    static let killGrace: TimeInterval = 1

    /// Reaps a child that was just sent SIGKILL, polling without blocking
    /// for `killGrace`. One stuck in the kernel is handed to `Reaper` and
    /// retried on later runs: no wait here can outlast the grace.
    static func reapAfterKill(_ pid: pid_t) {
        let end = uptime() + killGrace
        while uptime() < end {
            if reap(pid) != nil { return }
            usleep(10_000)
        }
        Reaper.adopt(pid)
    }

    /// Signals the child's process group, and the child itself while it is
    /// still unreaped, in case it moved to another group. A reaped child's
    /// pid may already belong to someone else, so it is never signalled.
    static func signal(_ pid: pid_t, _ sig: Int32, reaped: Bool) {
        kill(-pid, sig)
        if !reaped { kill(pid, sig) }
    }

    /// The child's wait status once it has exited, or nil while it runs.
    /// Never blocks: nothing in the agent waits on a child without a deadline.
    static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result == -1, errno == EINTR { continue }
            return nil
        }
    }

    /// The shell's convention: the exit code, or 128 plus the signal.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// The app's environment with the install directories in front of PATH,
    /// so anything cswap itself runs resolves the way it does in a shell.
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (locator.searchDirectories.map(\.path) + [inherited]).joined(separator: ":")
        return env
    }

    static func uptime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}

/// The read ends of the two pipes, polled together.
struct PipeReaders {
    enum Chunk {
        case none
        case stdout(Data)
        case stderr(Data)
    }

    private var out: Int32
    private var err: Int32
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    init(out: Int32, err: Int32) {
        self.out = out
        self.err = err
        for fd in [out, err] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
    }

    var allClosed: Bool { out < 0 && err < 0 }
    var stdoutClosed: Bool { out < 0 }

    /// Waits up to `waitMilliseconds` for either pipe, then reads one chunk.
    /// End of file closes that pipe.
    mutating func readAvailable(waitMilliseconds: Int32) -> Chunk {
        var fds: [pollfd] = []
        if out >= 0 { fds.append(pollfd(fd: out, events: Int16(POLLIN), revents: 0)) }
        if err >= 0 { fds.append(pollfd(fd: err, events: Int16(POLLIN), revents: 0)) }
        guard !fds.isEmpty else {
            usleep(UInt32(waitMilliseconds) * 1000)
            return .none
        }
        guard poll(&fds, nfds_t(fds.count), waitMilliseconds) > 0 else { return .none }
        for entry in fds where entry.revents != 0 {
            let n = buffer.withUnsafeMutableBytes { read(entry.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let data = Data(buffer[0..<n])
                return entry.fd == out ? .stdout(data) : .stderr(data)
            }
            if n == 0 || (errno != EAGAIN && errno != EINTR) {
                close(entry.fd)
                if entry.fd == out { out = -1 } else { err = -1 }
            }
        }
        return .none
    }

    mutating func closeAll() {
        if out >= 0 { close(out); out = -1 }
        if err >= 0 { close(err); err = -1 }
    }
}

/// Killed children that had not exited within the kill grace (stuck in the
/// kernel, say). Each run retries them without blocking, so none is left a
/// zombie for longer than it has to be.
enum Reaper {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: Set<pid_t> = []

    static func adopt(_ pid: pid_t) {
        lock.withLock { _ = pending.insert(pid) }
    }

    static func sweep() {
        lock.withLock {
            pending = pending.filter { ProcessCswapRunner.reap($0) == nil }
        }
    }

    static var count: Int { lock.withLock { pending.count } }
}
