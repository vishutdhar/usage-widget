import Foundation

/// A press of the widget's refresh button. The widget's intent writes it
/// into the shared container; the agent answers it with an immediate poll
/// and one reload.
public struct RefreshRequest: Codable, Equatable, Sendable {
    public var requestedAt: Date
    /// One more than the previous press: presses are told apart by number,
    /// never by the wall clock, which can be set back.
    public var sequence: Int
    /// A random id for the file the numbers belong to. When the file is
    /// deleted or damaged the numbers start again at 1 under a new session.
    public var session: String
    /// The snapshot on disk when the press was made (its writer and write
    /// number): any snapshot from another writer, or the same writer's
    /// later number, answers the press.
    public var afterSnapshot: Int
    public var afterWriter: String

    public init(requestedAt: Date, sequence: Int = 0, session: String = "", afterSnapshot: Int = 0,
                afterWriter: String = "") {
        self.requestedAt = requestedAt
        self.sequence = sequence
        self.session = session
        self.afterSnapshot = afterSnapshot
        self.afterWriter = afterWriter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestedAt = try c.decode(Date.self, forKey: .requestedAt)
        sequence = try c.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        afterSnapshot = try c.decodeIfPresent(Int.self, forKey: .afterSnapshot) ?? 0
        afterWriter = try c.decodeIfPresent(String.self, forKey: .afterWriter) ?? ""
    }
}

/// What the footer says about a press: "Refreshing…" until the agent
/// answers, then the plain "as of" line. A press is never held back, so
/// there is nothing else to say.
public enum RefreshFooter: Equatable, Sendable {
    case none
    /// Waiting for the agent: "Refreshing…".
    case refreshing
}

public enum RefreshRequestStore {
    public static let fileName = "refresh-request.json"

    /// Writes a request made at `date` into `directory`, atomically,
    /// numbered one past the previous one. This and waiting for the answer
    /// are all the widget's intent does: the extension never runs a process.
    @discardableResult
    public static func request(in directory: URL, at date: Date) throws -> RefreshRequest {
        let seen = SnapshotStore.read(from: directory.appendingPathComponent(SharedContainer.snapshotFileName))?.mark
            ?? SnapshotMark(writer: "", sequence: 0)
        let request: RefreshRequest
        let next = read(in: directory).flatMap { previous -> (Int, String)? in
            let (sequence, overflow) = previous.sequence.addingReportingOverflow(1)
            return overflow || !WriterState.isValid(sequence) ? nil : (sequence, previous.session)
        }
        if let (sequence, session) = next {
            request = RefreshRequest(requestedAt: date, sequence: sequence, session: session,
                                     afterSnapshot: seen.sequence, afterWriter: seen.writer)
        } else {
            // No readable file, or its numbers ran out: a new session at 1.
            request = RefreshRequest(requestedAt: date, sequence: 1, session: UUID().uuidString,
                                     afterSnapshot: seen.sequence, afterWriter: seen.writer)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try AtomicFile.write(try encoder.encode(request), to: directory.appendingPathComponent(fileName))
        return request
    }

    /// Waits, up to `timeout`, for the agent to write a snapshot newer than
    /// the press. The intent does this before returning, so the reload
    /// WidgetKit makes after it (not counted against the budget) already
    /// shows the fresh numbers, even when the agent's own reload is held.
    public enum WaitOutcome: Equatable, Sendable {
        case answered
        case timedOut
        case cancelled
    }

    /// - Parameter read: reads the snapshot; tests count the reads.
    /// How long the intent waits for the answering snapshot, and how often
    /// it looks.
    public static let intentWait: TimeInterval = 5
    public static let intentPoll: TimeInterval = 0.25

    public static func waitForAnswer(in directory: URL, to request: RefreshRequest, timeout: TimeInterval = intentWait,
                                     interval: TimeInterval = intentPoll,
                                     read: @Sendable (URL) -> UsageSnapshot? = { SnapshotStore.read(from: $0) })
        async -> WaitOutcome
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(Int(timeout * 1000)))
        let url = directory.appendingPathComponent(SharedContainer.snapshotFileName)
        while true {
            if RefreshState.answers(read(url)?.mark, request) { return .answered }
            if clock.now >= deadline { return .timedOut }
            do {
                try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            } catch {
                // Cancelled: stop at once, without another read.
                return .cancelled
            }
        }
    }

    /// The last request, or nil when there is none or it cannot be read.
    /// Nil when missing, unreadable, or numbered outside 0..<Int.max/2.
    public static func read(in directory: URL) -> RefreshRequest? {
        guard case .data(let data) = SafeFile.read(directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let request = try? decoder.decode(RefreshRequest.self, from: data),
              request.requestedAt.timeIntervalSince1970.isFinite,
              WriterState.isValid(request.sequence), WriterState.isValid(request.afterSnapshot) else { return nil }
        return request
    }
}

public enum RefreshState {
    /// How long the widget says "Refreshing…" at most.
    public static let window: TimeInterval = 90

    /// A request the agent has not answered yet: made within the last
    /// `window`, and no answering snapshot on hand.
    public static func pending(_ request: RefreshRequest?, snapshot: SnapshotMark?, at date: Date) -> Bool {
        guard isUserReload(request, at: date), let request else { return false }
        return !answers(snapshot, request)
    }

    /// A snapshot answers a press when it comes from another writer than
    /// the one the press saw (a restart, numbering begun again), or from
    /// the same writer with a later number.
    public static func answers(_ snapshot: SnapshotMark?, _ request: RefreshRequest) -> Bool {
        guard let snapshot else { return false }
        return snapshot.writer != request.afterWriter || snapshot.sequence > request.afterSnapshot
    }

    /// The footer for a press: "Refreshing…" until the agent answers.
    public static func footer(request: RefreshRequest?, snapshot: SnapshotMark?, at date: Date) -> RefreshFooter {
        pending(request, snapshot: snapshot, at: date) ? .refreshing : .none
    }

    /// A widget reload within the window after a press is the user's own.
    public static func isUserReload(_ request: RefreshRequest?, at date: Date) -> Bool {
        guard let request else { return false }
        let age = date.timeIntervalSince(request.requestedAt)
        return age >= 0 && age < window
    }
}
