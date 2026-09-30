import Foundation

public enum SnapshotStore {
    public static func encode(_ snapshot: UsageSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISODate.format(date))
        }
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> UsageSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = ISODate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(text)")
            }
            return date
        }
        return try decoder.decode(UsageSnapshot.self, from: data)
    }

    /// The snapshot at `url`, or nil when it is missing, unreadable, or from
    /// a schema this build does not understand.
    /// A snapshot whose write number is outside 0..<`maxWriteSequence`
    /// is corrupt and reads as missing.
    public static func read(from url: URL) -> UsageSnapshot? {
        guard case .data(let data) = SafeFile.read(url),
              let snapshot = try? decode(data),
              snapshot.schemaVersion == UsageSnapshot.currentSchemaVersion,
              snapshot.writeSequence.map(WriterState.isValid) ?? true
        else { return nil }
        return snapshot
    }

    /// Validates, encodes and atomically writes the snapshot.
    public static func write(_ snapshot: UsageSnapshot, to url: URL) throws {
        try AtomicFile.write(try encode(SnapshotValidator.sanitized(snapshot)), to: url)
    }
}

public struct WriteOutcome: Equatable, Sendable {
    /// The number this write carries.
    public var sequence: Int
    /// Set when the file on disk carried a number past the writer's own
    /// last one (another writer's), which was taken as the new baseline.
    public var adopted: Int?
    /// The writer id written: the snapshot's own, or a new one when the
    /// numbers wrapped to 1.
    public var writerId: String?
}

extension SnapshotStore {
    /// Writes the snapshot numbered one past the higher of the writer's own
    /// last number and the file's (a corrupt file counts as none). A higher
    /// number from another writer is adopted rather than obeyed, so it can
    /// never freeze the writer; wall times play no part.
    public static func writeNumbered(_ snapshot: UsageSnapshot, to url: URL, after lastSequence: Int?) throws
        -> WriteOutcome
    {
        let own = lastSequence.flatMap { WriterState.isValid($0) ? $0 : nil } ?? 0
        let disk = read(from: url)?.writeSequence ?? 0
        var numbered = snapshot
        let (next, overflow) = max(disk, own).addingReportingOverflow(1)
        if overflow || !WriterState.isValid(next) {
            // Past the last valid number: start again at 1 under a new
            // writer id in the same write, so a press waiting on the old
            // numbers counts this as its answer.
            numbered.writeSequence = 1
            numbered.writerId = UUID().uuidString
        } else {
            numbered.writeSequence = next
        }
        try write(numbered, to: url)
        return WriteOutcome(sequence: numbered.writeSequence ?? 1, adopted: disk > own ? disk : nil,
                            writerId: numbered.writerId)
    }
}

/// The agent's own record of its last write number (`writer-state.json`).
public struct WriterState: Codable, Equatable, Sendable {
    public var lastSequence: Int

    public init(lastSequence: Int) {
        self.lastSequence = lastSequence
    }

    /// Numbers stay far from overflow; anything else is corrupt.
    public static let maxSequence = Int.max / 2

    public static func isValid(_ sequence: Int) -> Bool {
        sequence >= 0 && sequence < maxSequence
    }
}

public enum WriterStateStore {
    public static let fileName = "writer-state.json"

    public static func read(in directory: URL) -> WriterState? {
        guard case .data(let data) = SafeFile.read(directory.appendingPathComponent(fileName)),
              let state = try? JSONDecoder().decode(WriterState.self, from: data),
              WriterState.isValid(state.lastSequence) else { return nil }
        return state
    }

    public static func write(_ state: WriterState, in directory: URL) throws {
        try SafeFile.write(try JSONEncoder().encode(state), to: directory.appendingPathComponent(fileName))
    }
}

public enum SnapshotValidator {
    /// The snapshot with every number made safe to store and to show.
    ///
    /// JSON has no NaN or infinity, and a view converting an absurd number to
    /// an integer would trap, so nothing unusable reaches the file:
    /// percents outside 0...`maxPct` become unknown (negatives 0), pace is
    /// clamped to 0...100, amounts must be finite, lengths non-negative, and
    /// dates finite.
    /// Error text and status notes pass through the redactor here, the one
    /// place every snapshot goes through before it is written.
    public static func sanitized(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        var copy = snapshot
        for p in copy.providers.indices {
            copy.providers[p].error = copy.providers[p].error.map(Redactor.redactEmails)
            copy.providers[p].collectorError = copy.providers[p].collectorError.map(Redactor.redactEmails)
            for a in copy.providers[p].accounts.indices {
                copy.providers[p].accounts[a].statusNote = copy.providers[p].accounts[a].statusNote.map(Redactor.redactEmails)
                copy.providers[p].accounts[a].fetchedAt = finiteDate(copy.providers[p].accounts[a].fetchedAt)
                copy.providers[p].accounts[a].ageSeconds = copy.providers[p].accounts[a].ageSeconds
                    .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                copy.providers[p].accounts[a].windows = copy.providers[p].accounts[a].windows.map(sanitized)
            }
        }
        return copy
    }

    static func sanitized(_ window: UsageWindow) -> UsageWindow {
        var w = window
        if let pct = w.usedPct {
            w.usedPct = pct.isFinite && pct <= UsageWindow.maxPct ? max(0, pct) : nil
        }
        w.expectedPct = w.expectedPct.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        w.amount = w.amount.flatMap { $0.isFinite ? $0 : nil }
        w.limit = w.limit.flatMap { $0.isFinite ? $0 : nil }
        w.windowSeconds = max(0, w.windowSeconds)
        w.resetsAt = finiteDate(w.resetsAt)
        return w
    }

    static func finiteDate(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970.isFinite else { return nil }
        return date
    }
}
