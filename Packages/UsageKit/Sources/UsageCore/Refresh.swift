import Foundation

/// A press of the widget's refresh button. The widget's intent writes it
/// into the shared container and returns; the agent answers it with an
/// immediate fresh poll and, once that answer is written, one reload.
public struct RefreshRequest: Codable, Equatable, Sendable {
    public var requestedAt: Date
    /// One more than the previous press: presses are told apart by number,
    /// never by the wall clock, which can be set back.
    public var sequence: Int
    /// A random id for the file the numbers belong to. When the file is
    /// deleted or damaged the numbers start again at 1 under a new session.
    public var session: String
    /// The snapshot on disk when the press was made (its writer and write
    /// number), for diagnosis. A press is answered only by a snapshot that
    /// names it (`UsageSnapshot.answeredPress`), never merely by a newer one.
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

/// A press named by a snapshot as answered: the session and number of the
/// newest press answered when the snapshot was written. It answers every
/// press of that session up to that number.
public struct AnsweredPress: Codable, Equatable, Sendable {
    public var session: String
    public var sequence: Int

    public init(session: String, sequence: Int) {
        self.session = session
        self.sequence = sequence
    }

    public init(_ request: RefreshRequest) {
        self.init(session: request.session, sequence: request.sequence)
    }

    public func answers(_ request: RefreshRequest) -> Bool {
        session == request.session && sequence >= request.sequence
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

    /// What the refresh button's intent does, all of it: re-anchors a
    /// container replaced at its path, writes the numbered request, and
    /// returns at once. It never waits for the agent: WidgetKit's reload
    /// after the intent then says "Refreshing…" (the pending press), and
    /// the agent's own reload, once its snapshot answers the press, brings
    /// the numbers.
    @discardableResult
    public static func press(in directory: URL, at date: Date) throws -> RefreshRequest {
        _ = ContainerRoot.revalidate(directory)
        return try request(in: directory, at: date)
    }

    /// Writes a request made at `date` into `directory`, atomically,
    /// numbered one past the previous one. This and waiting for the answer
    /// are all the widget's intent does: the extension never runs a process.
    @discardableResult
    public static func request(in directory: URL, at date: Date) throws -> RefreshRequest {
        let seen = SnapshotStore.read(from: directory.appendingPathComponent(SharedContainer.snapshotFileName))?.mark
            ?? SnapshotMark(writer: "", sequence: 0)
        let request: RefreshRequest
        let next = read(in: directory).flatMap { previous -> (Int, String)? in
            // A file without a session id (an earlier build's) starts a new one.
            guard !previous.session.isEmpty else { return nil }
            let (sequence, overflow) = previous.sequence.addingReportingOverflow(1)
            return overflow || !WriterState.isValid(sequence) ? nil : (sequence, previous.session)
        }
        if let (sequence, session) = next {
            request = RefreshRequest(requestedAt: date, sequence: sequence, session: session,
                                     afterSnapshot: seen.sequence, afterWriter: seen.writer)
        } else {
            // No readable file, no session id, or its numbers ran out: a new
            // session at 1.
            request = RefreshRequest(requestedAt: date, sequence: 1, session: UUID().uuidString,
                                     afterSnapshot: seen.sequence, afterWriter: seen.writer)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try AtomicFile.write(try encoder.encode(request), to: directory.appendingPathComponent(fileName))
        return request
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
    /// How long the widget says "Refreshing…" at most. An answered press
    /// ends it in a second or three; a press the agent never answers shows
    /// the last measured time again after this.
    public static let window: TimeInterval = 90

    /// A request the agent has not answered yet: made within the last
    /// `window`, and no answering snapshot on hand.
    public static func pending(_ request: RefreshRequest?, snapshot: UsageSnapshot?, at date: Date) -> Bool {
        guard isUserReload(request, at: date), let request else { return false }
        return !answers(snapshot, request)
    }

    /// A snapshot answers a press when it names the press, or a later press
    /// of its session, as answered. Its writer and write number play no
    /// part, so a background poll's snapshot written after the press does
    /// not answer it, and a restart or a wrap of the numbers cannot fake an
    /// answer.
    public static func answers(_ snapshot: UsageSnapshot?, _ request: RefreshRequest) -> Bool {
        snapshot?.answeredPress?.answers(request) ?? false
    }

    /// The footer for a press: "Refreshing…" until the agent answers.
    public static func footer(request: RefreshRequest?, snapshot: UsageSnapshot?, at date: Date) -> RefreshFooter {
        pending(request, snapshot: snapshot, at: date) ? .refreshing : .none
    }

    /// A widget reload within the window after a press is the user's own.
    public static func isUserReload(_ request: RefreshRequest?, at date: Date) -> Bool {
        guard let request else { return false }
        let age = date.timeIntervalSince(request.requestedAt)
        return age >= 0 && age < window
    }
}
