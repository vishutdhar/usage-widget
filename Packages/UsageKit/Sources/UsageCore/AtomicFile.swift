import Foundation

public enum AtomicFile {
    /// Writes `data` to a temporary file in the same directory, then renames
    /// it over `url`. A reader sees the old file or the new one, never a
    /// half-written file.
    public static func write(_ data: Data, to url: URL) throws {
        try SafeFile.write(data, to: url)
    }
}

/// A text log that keeps only its newest lines.
public enum CappedLog {
    /// Appends one line, then trims the file to its newest `cap` lines.
    /// A lock file serialises writers, so two widget instances logging at
    /// once cannot drop each other's lines.
    public static func append(_ line: String, to url: URL, cap: Int) throws {
        try append(line, to: url, cap: cap, whileLocked: {})
    }

    /// - Parameter whileLocked: runs once the lock is held; tests swap the
    ///   folder there.
    static func append(_ line: String, to url: URL, cap: Int, whileLocked: () -> Void) throws {
        // The folder is looked up once: the lock, the read and the write
        // all use it, whatever a revalidate does while this runs.
        let log: SafeFile.Place
        switch SafeFile.place(url) {
        case .success(let place): log = place
        case .failure(.missing): throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.deletingLastPathComponent().path])
        case .failure(.refused(let reason)): throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard let lock = log.sibling(log.name + ".lock") else { throw CocoaError(.fileWriteInvalidFileName) }
        let fd = SafeFile.openLock(lock)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        // Never wait on a stuck holder: logging must not block a poll or
        // the widget's timeline. Try for up to 250 ms, then skip the line.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        while !locked, ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
            locked = flock(fd, LOCK_EX | LOCK_NB) == 0
        }
        guard locked else { return }
        defer { flock(fd, LOCK_UN) }
        whileLocked()

        let existing: String
        switch SafeFile.read(log) {
        case .data(let data): existing = String(decoding: data, as: UTF8.self)
        case .missing: existing = ""
        case .refused(let reason): throw CocoaError(.fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(line.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " "))
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        try SafeFile.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: log)
    }
}
