import Darwin
import Foundation

/// A folder held open as a directory descriptor. It is anchored once: the
/// path must name a real directory (not a link), opened with O_DIRECTORY
/// and O_NOFOLLOW, and the descriptor must be the same directory lstat saw.
/// After that the path is never used again: every file operation is made
/// relative to the descriptor with a single-component name, so swapping
/// another folder in at the path cannot redirect anything.
public final class ContainerRoot: @unchecked Sendable {
    public let fd: Int32
    public let url: URL
    /// The anchored directory's identity.
    public let device: UInt64
    public let inode: UInt64

    private init(fd: Int32, url: URL, device: UInt64, inode: UInt64) {
        self.fd = fd
        self.url = url
        self.device = device
        self.inode = inode
    }

    deinit { close(fd) }

    public enum Anchor {
        case anchored(ContainerRoot)
        case missing
        case refused(String)
    }

    /// Opens `url` as a folder, fresh.
    public static func anchor(_ url: URL) -> Anchor {
        var before = stat()
        guard lstat(url.path, &before) == 0 else {
            return errno == ENOENT ? .missing : .refused(String(cString: strerror(errno)))
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .refused(String(cString: strerror(errno))) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, SafeFile.sameFile(st, before) else {
            close(fd)
            return .refused("changed while opening")
        }
        return .anchored(ContainerRoot(fd: fd, url: url, device: UInt64(st.st_dev), inode: UInt64(st.st_ino)))
    }

    /// A folder inside this one, opened relative to it with O_DIRECTORY and
    /// O_NOFOLLOW: a link, or a name that is not a plain component, gives nil.
    public func child(_ name: String) -> ContainerRoot? {
        guard SafeFile.isPlainName(name) else { return nil }
        let fd = openat(self.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            close(fd)
            return nil
        }
        return ContainerRoot(fd: fd, url: url.appendingPathComponent(name, isDirectory: true),
                             device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
    }

    /// The names in this folder, read through its descriptor.
    public func names() -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let dir = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Whether `st` (an lstat of the path) names this anchored folder: the
    /// same device and the same inode.
    public func isSame(as st: stat) -> Bool {
        device == UInt64(st.st_dev) && inode == UInt64(st.st_ino)
    }

    public enum Revalidation: Equatable, Sendable {
        /// The path still names the anchored folder (or was anchored now
        /// for the first time).
        case unchanged
        /// Another folder now sits at the path. It is anchored from here on
        /// when it passes the anchor's checks; one that cannot be opened is
        /// still a replacement, and the old anchor stays.
        case replaced
        case missing
        /// The path could not be checked at all.
        case refused(String)
    }

    /// Checks that the path still names the anchored folder. The identity
    /// (device and inode, not following a link) is compared first: a
    /// different one is `.replaced` whether or not the new folder opens.
    /// A replacement that opens is anchored with the same checks and used
    /// from the next operation on; an operation already under way keeps
    /// the descriptor it started with. The agent calls this every poll,
    /// the intent every press, and the widget every timeline.
    public static func revalidate(_ url: URL) -> Revalidation {
        let key = url.standardizedFileURL.path
        return lock.withLock {
            var now = stat()
            guard lstat(url.path, &now) == 0 else {
                return errno == ENOENT ? .missing : .refused(String(cString: strerror(errno)))
            }
            if let cached = roots[key] {
                guard !cached.isSame(as: now) else { return .unchanged }
                if case .anchored(let root) = anchor(url) { roots[key] = root }
                return .replaced
            }
            switch anchor(url) {
            case .anchored(let root):
                roots[key] = root
                return .unchanged
            case .missing:
                return .missing
            case .refused(let reason):
                return .refused(reason)
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var roots: [String: ContainerRoot] = [:]

    /// The folder anchored once for this process; later calls reuse the
    /// same descriptor whatever now sits at the path.
    public static func shared(for url: URL) -> Anchor {
        let key = url.standardizedFileURL.path
        return lock.withLock {
            if let root = roots[key] { return .anchored(root) }
            let result = anchor(url)
            if case .anchored(let root) = result { roots[key] = root }
            return result
        }
    }
}

/// The one way files are opened, read and written: the shared container's
/// files (snapshot, refresh request and result, reload and writer state,
/// Codex call log, both logs, the lock) through their folder's anchored
/// descriptor, and the primitives Codex's rollout reader uses.
///
/// A file is used only when fstatat (not following links) shows a regular
/// file with a single link; it is opened with openat, O_NOFOLLOW,
/// O_NONBLOCK and O_CLOEXEC, and fstat must then show that same file.
/// A write creates a new file exclusively beside the target and renames it
/// over the target, which replaces a link rather than writing through it.
public enum SafeFile {
    public enum ReadResult: Equatable, Sendable {
        case data(Data)
        case missing
        case refused(String)
    }

    /// Container files are small; nothing larger is read.
    public static let maxBytes = 16 * 1024 * 1024

    /// For files outside the container (rollouts), by path.
    public static func openNoFollow(_ path: String) -> Int32 {
        Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }

    public static func openAtNoFollow(_ dirfd: Int32, _ name: String) -> Int32 {
        openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }

    public static func isSingleRegular(_ st: stat) -> Bool {
        (st.st_mode & S_IFMT) == S_IFREG && st.st_nlink == 1
    }

    public static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// A single path component: no slash, not "." or "..", not empty.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    /// The real path of `path`, or nil when it cannot be resolved.
    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Reads up to `count` bytes from `offset` with bounded pread calls;
    /// fewer when the file ends first. Nil on a read error.
    public static func readRange(_ fd: Int32, offset: Int, count: Int) -> Data? {
        var data = Data(count: count)
        var filled = 0
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            while filled < count {
                let n = pread(fd, buffer.baseAddress! + filled, count - filled, off_t(offset + filled))
                if n > 0 { filled += n; continue }
                if n == 0 { return true }
                if errno == EINTR { continue }
                return false
            }
            return true
        }
        guard ok else { return nil }
        data.count = filled
        return data
    }

    /// A file in an anchored folder, looked up once. An operation reads
    /// the folder's anchor at its entry and uses that same descriptor for
    /// every step (a log's lock, read and write), so a revalidate part way
    /// through can never split it across two folders.
    public struct Place {
        public let root: ContainerRoot
        public let name: String
        /// For error messages only; never opened.
        public let url: URL

        /// Another plain name in the same anchored folder.
        public func sibling(_ other: String) -> Place? {
            guard SafeFile.isPlainName(other) else { return nil }
            return Place(root: root, name: other, url: url.deletingLastPathComponent().appendingPathComponent(other))
        }
    }

    /// The anchored folder of `url` and its plain name, or why there is none.
    public static func place(_ url: URL) -> Result<Place, LocateFailure> {
        let name = url.lastPathComponent
        guard isPlainName(name) else { return .failure(.refused("not a plain file name")) }
        switch ContainerRoot.shared(for: url.deletingLastPathComponent()) {
        case .anchored(let root): return .success(Place(root: root, name: name, url: url))
        case .missing: return .failure(.missing)
        case .refused(let reason): return .failure(.refused("folder: \(reason)"))
        }
    }

    public enum LocateFailure: Error, Equatable {
        case missing
        case refused(String)

        var readResult: ReadResult {
            switch self {
            case .missing: return .missing
            case .refused(let reason): return .refused(reason)
            }
        }
    }

    /// The whole file, when it passes every check.
    /// - Parameter open: opens a name in the folder; tests record opens.
    public static func read(_ url: URL, maxBytes: Int = SafeFile.maxBytes,
                            open: (Int32, String) -> Int32 = SafeFile.openAtNoFollow) -> ReadResult {
        switch place(url) {
        case .success(let place): return read(place, maxBytes: maxBytes, open: open)
        case .failure(let failure): return failure.readResult
        }
    }

    /// Looks at a file this many times when it is replaced between the
    /// check and the open (the agent's own atomic rename can land there).
    public static let openAttempts = 3

    /// - Parameter open: opens a name in the folder; tests record opens.
    public static func read(_ place: Place, maxBytes: Int = SafeFile.maxBytes,
                            open: (Int32, String) -> Int32 = SafeFile.openAtNoFollow) -> ReadResult {
        let root = place.root
        for attempt in 1...openAttempts {
            var before = stat()
            if fstatat(root.fd, place.name, &before, AT_SYMLINK_NOFOLLOW) != 0 {
                return errno == ENOENT ? .missing : .refused(String(cString: strerror(errno)))
            }
            guard isSingleRegular(before) else { return .refused("not a regular file") }
            let fd = open(root.fd, place.name)
            guard fd >= 0 else { return errno == ENOENT ? .missing : .refused(String(cString: strerror(errno))) }
            defer { close(fd) }
            var st = stat()
            guard fstat(fd, &st) == 0, isSingleRegular(st) else { return .refused("changed while opening") }
            // Another file than the one checked: look again, and refuse
            // only when it keeps changing.
            guard sameFile(st, before) else {
                if attempt < openAttempts { continue }
                return .refused("changed while opening")
            }
            guard st.st_size >= 0, st.st_size <= maxBytes else { return .refused("too large") }
            guard let data = readRange(fd, offset: 0, count: Int(st.st_size)) else { return .refused("could not be read") }
            return .data(data)
        }
        return .refused("changed while opening")
    }

    /// Writes `data` over `url` atomically: a new file, created exclusively
    /// in the anchored folder, renamed over the target.
    public static func write(_ data: Data, to url: URL) throws {
        switch place(url) {
        case .success(let place): try write(data, to: place)
        case .failure(let failure):
            let folder = url.deletingLastPathComponent().path
            if failure == .missing { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: folder]) }
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: folder])
        }
    }

    public static func write(_ data: Data, to place: Place) throws {
        let root = place.root
        var existing = stat()
        if fstatat(root.fd, place.name, &existing, AT_SYMLINK_NOFOLLOW) == 0, (existing.st_mode & S_IFMT) == S_IFDIR {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: place.url.path])
        }
        let temporary = ".\(place.name).tmp-\(UUID().uuidString)"
        let fd = openat(root.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var written = 0
        let ok = data.withUnsafeBytes { buffer -> Bool in
            while written < data.count {
                let n = Darwin.write(fd, buffer.baseAddress! + written, data.count - written)
                if n > 0 { written += n; continue }
                if n < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
        var st = stat()
        let regular = fstat(fd, &st) == 0 && isSingleRegular(st)
        close(fd)
        guard ok, regular, renameat(root.fd, temporary, root.fd, place.name) == 0 else {
            let code = errno
            unlinkat(root.fd, temporary, 0)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Removes the file (a link is removed, never followed).
    public static func remove(_ url: URL) {
        guard case .success(let place) = place(url) else { return }
        unlinkat(place.root.fd, place.name, 0)
    }

    /// Opens (creating when missing) a lock file for flock: never through a
    /// link, and only a regular single-link file. -1 with errno set otherwise.
    /// Writes the lock holder's pid into the agent lock, on the locked
    /// descriptor itself (the inode the lock is on). Nil, or the error.
    public static func publishLockHolder(_ fd: Int32, pid: Int32) -> String? {
        if let error = clearLockHolder(fd) { return error }
        let bytes = Array("\(pid)".utf8)
        let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard written == bytes.count else { return written < 0 ? String(cString: strerror(errno)) : "short write" }
        return nil
    }

    /// The pid in the agent lock, read on a descriptor of that file; nil
    /// when none was written (or it was cleared).
    public static func readLockHolder(_ fd: Int32) -> Int32? {
        guard let data = readRange(fd, offset: 0, count: 32) else { return nil }
        return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Empties the agent lock before its holder lets go. Nil, or the error.
    public static func clearLockHolder(_ fd: Int32) -> String? {
        ftruncate(fd, 0) == 0 ? nil : String(cString: strerror(errno))
    }

    public static func openLock(_ url: URL) -> Int32 {
        guard case .success(let place) = place(url) else {
            errno = EACCES
            return -1
        }
        return openLock(place)
    }

    public static func openLock(_ place: Place) -> Int32 {
        let fd = openat(place.root.fd, place.name, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return -1 }
        var st = stat()
        guard fstat(fd, &st) == 0, isSingleRegular(st) else {
            close(fd)
            errno = EFTYPE
            return -1
        }
        return fd
    }
}
