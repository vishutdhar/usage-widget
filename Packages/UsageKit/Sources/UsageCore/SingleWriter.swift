import Foundation

/// An exclusive lock held for the life of the process, so only one agent
/// polls cswap and writes the snapshot.
public final class InstanceLock: @unchecked Sendable {
    public let url: URL
    private let fd: Int32

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    public enum Outcome {
        case acquired(InstanceLock)
        /// Another holder has it: an agent is already running.
        case heldElsewhere
        /// The lock file could not be used at all.
        case failed(String)

        public enum Kind: Equatable, Sendable {
            case acquired
            case heldElsewhere
            case failed(String)
        }

        public var kind: Kind {
            switch self {
            case .acquired: return .acquired
            case .heldElsewhere: return .heldElsewhere
            case .failed(let reason): return .failed(reason)
            }
        }

        public var lock: InstanceLock? {
            if case .acquired(let lock) = self { return lock }
            return nil
        }
    }

    /// Takes the lock without waiting. Only "another holder has it" means an
    /// agent is running; any other failure is an error to show.
    public static func acquire(at url: URL) -> Outcome {
        let fd = SafeFile.openLock(url)
        guard fd >= 0 else { return .failed(String(cString: strerror(errno))) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            return code == EWOULDBLOCK ? .heldElsewhere : .failed(String(cString: strerror(code)))
        }
        return .acquired(InstanceLock(url: url, fd: fd))
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Masks personal details in text that leaves the agent: the snapshot's
/// error and status notes, the status window, and the logs.
public enum Redactor {
    /// Each email keeps the first three characters of its local part and its
    /// top level domain: "someone@example.com" becomes "som***@***.com".
    /// A quoted local part ("john \"doe\""@example.com, escapes included)
    /// keeps nothing. Plus addresses are covered; typographic quotes around
    /// an address, as in system error messages, stay outside it.
    public static func redactEmails(_ text: String) -> String {
        let pattern = /("(?:[^"\\]|\\.)*"|[^\s"<>(),;:@\u{201C}\u{201D}\u{2018}\u{2019}`]+)@([A-Za-z0-9.\-]+)\.([A-Za-z]{2,})/
        return text.replacing(pattern) { match in
            // A quoted local part can hold anything, escaped quotes included,
            // so it keeps nothing; an ordinary one keeps three characters.
            let local = match.output.1
            let kept = local.hasPrefix("\"") ? "" : String(local.prefix(3))
            return "\(kept)***@***.\(match.output.3)"
        }
    }
}
