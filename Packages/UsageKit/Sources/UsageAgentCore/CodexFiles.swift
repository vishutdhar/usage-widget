import Foundation
import UsageCore

/// Where Codex keeps its files.
public struct CodexPaths: Sendable {
    public var home: URL
    /// Homebrew and /usr/local/bin; replaceable so tests can model a Mac
    /// without Codex.
    public var systemDirectories: [URL]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                systemDirectories: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                                            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)]) {
        self.home = home
        self.systemDirectories = systemDirectories
    }

    public var codexHome: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    public var sessions: URL { codexHome.appendingPathComponent("sessions", isDirectory: true) }

    /// Homebrew first (the CLI is a node script installed there), then
    /// /usr/local/bin, then ~/.local/bin.
    public var binaryCandidates: [URL] {
        searchDirectories.map { $0.appendingPathComponent("codex") }
    }

    public func resolveBinary(isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) -> URL? {
        binaryCandidates.first(where: isExecutable)
    }

    /// Directories the app-server child needs on its PATH (node lives in Homebrew).
    public var searchDirectories: [URL] {
        systemDirectories + [home.appendingPathComponent(".local/bin", isDirectory: true)]
    }
}

/// A rollout file as discovery saw it through lstat: a regular file with
/// one link, identified by device and inode so a later open can prove it
/// is still the same file.
public struct RolloutFile: Equatable, Sendable {
    public var path: String
    public var modified: Date
    public var device: UInt64
    public var inode: UInt64
    /// The day folder discovery found it in, held open: the file is opened
    /// relative to it, so a later swap of any folder above cannot redirect
    /// the open. Nil for a file described by path alone.
    public var folder: ContainerRoot?

    public init(path: String, modified: Date, device: UInt64, inode: UInt64, folder: ContainerRoot? = nil) {
        self.path = path
        self.modified = modified
        self.device = device
        self.inode = inode
        self.folder = folder
    }

    public static func == (a: RolloutFile, b: RolloutFile) -> Bool {
        a.path == b.path && a.modified == b.modified && a.device == b.device && a.inode == b.inode
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }

    /// The file at `path` when lstat shows a regular file with a single
    /// link: never a symlink, directory, FIFO or device, and never a second
    /// name (hard link) for a file that lives elsewhere.
    public static func regular(at path: String) -> RolloutFile? {
        var st = stat()
        guard lstat(path, &st) == 0, SafeFile.isSingleRegular(st) else { return nil }
        return RolloutFile(path: path, modified: modified(st), device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
    }

    static func modified(_ st: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
    }

    func matches(_ st: stat) -> Bool {
        UInt64(st.st_dev) == device && UInt64(st.st_ino) == inode
    }
}

/// Finds the newest rollout files without walking the whole history.
public enum RolloutFinder {
    public static let daysScanned = 7
    /// How many of the newest files are read each poll.
    public static let filesRead = 5

    /// The newest regular `rollout-*.jsonl` files by modification time,
    /// newest first, among the day folders (sessions/YYYY/MM/DD) of the last
    /// seven days. The sessions folder is anchored as a descriptor for this
    /// poll and each day folder is reached from it one component at a time
    /// with openat, never through a link; files are checked with fstatat
    /// in their day folder, which each keeps.
    ///
    /// All seven are looked at, not only today and yesterday: a long
    /// session keeps writing to the file in the directory of the day it
    /// started.
    public static func newest(in sessions: URL, now: Date, calendar: Calendar = .current,
                              limit: Int = RolloutFinder.filesRead) -> [RolloutFile] {
        guard case .anchored(let root) = ContainerRoot.anchor(sessions) else { return [] }
        // Codex names the folders by the Gregorian calendar in local time,
        // whatever calendar the Mac is set to.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        var found: [RolloutFile] = []
        for offset in 0..<daysScanned {
            guard let day = gregorian.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = gregorian.dateComponents([.year, .month, .day], from: day)
            guard let y = parts.year, let m = parts.month, let d = parts.day,
                  let folder = root.child(String(format: "%04d", y))?.child(String(format: "%02d", m))?
                    .child(String(format: "%02d", d)) else { continue }
            for name in folder.names() where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                var st = stat()
                guard fstatat(folder.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, SafeFile.isSingleRegular(st) else { continue }
                found.append(RolloutFile(path: folder.url.appendingPathComponent(name).path, modified: RolloutFile.modified(st),
                                         device: UInt64(st.st_dev), inode: UInt64(st.st_ino), folder: folder))
            }
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }
}

public enum RolloutReader {
    public static let tailBytes = 512 * 1024

    /// The day folder to open the file in: the one discovery kept, or, for
    /// a file described by path alone, one reached from the anchored
    /// sessions folder through exactly year, month and day, each a plain
    /// component opened without following links. Nil when the path is not
    /// sessions/YYYY/MM/DD/name, so nothing outside the sessions folder
    /// (or directly in ~/.codex) is ever opened.
    static func folder(for file: RolloutFile, paths: CodexPaths) -> ContainerRoot? {
        if let folder = file.folder { return folder }
        let base = paths.sessions.standardizedFileURL.path
        let parent = URL(fileURLWithPath: file.path).deletingLastPathComponent().standardizedFileURL.path
        guard parent.hasPrefix(base + "/") else { return nil }
        let parts = parent.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard parts.count == 3, parts.allSatisfy(SafeFile.isPlainName),
              case .anchored(let root) = ContainerRoot.anchor(paths.sessions) else { return nil }
        return root.child(parts[0])?.child(parts[1])?.child(parts[2])
    }

    /// The last bytes of the file, at most `maxBytes` and at most its size
    /// when opened, starting at a line boundary. Nil when the file is
    /// refused, has changed identity since discovery, or cannot be read.
    /// Refused before any open: anything named auth.json, anything not in a
    /// sessions day folder, and anything fstatat (not following links) does
    /// not show as the same single-link regular file discovery found.
    ///
    /// - Parameters:
    ///   - opener: opens a name in the day folder; tests record opens.
    ///   - beforeRead: runs after the size is taken; tests append there.
    public static func tail(of file: RolloutFile, paths: CodexPaths, maxBytes: Int = RolloutReader.tailBytes,
                            opener: (Int32, String) -> Int32 = SafeFile.openAtNoFollow,
                            beforeRead: () -> Void = {}) -> Data? {
        let name = file.name
        guard name != "auth.json", SafeFile.isPlainName(name), let folder = folder(for: file, paths: paths) else { return nil }
        var before = stat()
        guard fstatat(folder.fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0, SafeFile.isSingleRegular(before),
              file.matches(before) else { return nil }
        let fd = opener(folder.fd, name)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, SafeFile.isSingleRegular(st), file.matches(st) else { return nil }

        let size = Int(max(0, st.st_size))
        let count = min(size, maxBytes)
        let offset = size - count
        beforeRead()
        guard var data = SafeFile.readRange(fd, offset: offset, count: count) else { return nil }
        if offset > 0 {
            // The first line was cut; start at the next one.
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
            data = data[(newline + 1)...]
        }
        return Data(data)
    }
}
