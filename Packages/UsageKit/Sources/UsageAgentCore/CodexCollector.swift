import Foundation
import UsageCore

/// Where the agent gets Codex readings. The app passes a `CodexCollector`;
/// tests pass a fake.
public protocol CodexSourcing: Sendable {
    /// Whether a codex binary or any rollout history exists.
    var codexFound: Bool { get }
    func rolloutReading(now: Date) -> CodexReading?
    func appServerReading() async -> Result<CodexReading, FetchFailure>
}

public struct CodexCollector: CodexSourcing {
    public var paths: CodexPaths
    public var client: CodexAppServerClient
    public var calendar: Calendar
    /// Told once per file when events dated ahead are skipped.
    public var debug: @Sendable (String) -> Void
    let futureLog = FutureEventLog()

    /// - Parameter client: defaults to one that looks for codex under the
    ///   same `paths`, so a collector pointed at another home can never
    ///   reach the real binary.
    public init(paths: CodexPaths = CodexPaths(), client: CodexAppServerClient? = nil, calendar: Calendar = .current,
                debug: @escaping @Sendable (String) -> Void = { _ in }) {
        self.paths = paths
        self.client = client ?? CodexAppServerClient(paths: paths)
        self.calendar = calendar
        self.debug = debug
    }

    public var codexFound: Bool {
        paths.resolveBinary() != nil || FileManager.default.fileExists(atPath: paths.sessions.path)
    }

    /// The newest reading by event time among the five most recently
    /// modified rollout files. Two sessions can run at once, and the file
    /// touched last need not hold the latest limits; a file with no valid
    /// limits in its tail (none, empty, or dated ahead) adds nothing.
    public func rolloutReading(now: Date) -> CodexReading? {
        RolloutFinder.newest(in: paths.sessions, now: now, calendar: calendar)
            .compactMap { file -> CodexReading? in
                guard let tail = RolloutReader.tail(of: file, paths: paths) else { return nil }
                let scan = CodexRolloutParser.scan(tail, now: now)
                if scan.skippedFuture, futureLog.firstTime(device: file.device, inode: file.inode) {
                    debug("a rollout file has events dated ahead of the clock; they are skipped")
                }
                return scan.reading
            }
            .max { $0.measuredAt < $1.measuredAt }
    }

    public func appServerReading() async -> Result<CodexReading, FetchFailure> {
        await client.readRateLimits()
    }
}

/// The "Show Codex" setting.
public enum CodexPreference {
    public static let key = "showCodex"

    /// A stored choice wins; until there is one, Codex shows when its
    /// folder (~/.codex) exists.
    public static func resolve(stored: Bool?, codexHomeExists: Bool) -> Bool {
        stored ?? codexHomeExists
    }
}

/// Which files have already been reported for events dated ahead; only
/// for logging, and forgotten wholesale when it grows.
final class FutureEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var files: Set<[UInt64]> = []

    func firstTime(device: UInt64, inode: UInt64) -> Bool {
        lock.withLock {
            if files.count > 64 { files.removeAll() }
            return files.insert([device, inode]).inserted
        }
    }
}
