import Foundation

/// The file the agent writes and the widget reads (`snapshot.json`).
///
/// One snapshot holds every provider the agent knows about: a `claude`
/// provider fed by `cswap list --json` and a `codex` provider, each an entry
/// in `providers`. A provider block that is missing simply renders nothing.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// For display only: when the agent wrote this. Order between writes is
    /// `writeSequence`, which a clock correction cannot reorder.
    public var writtenAt: Date
    public var providers: [ProviderUsage]
    /// One more than the snapshot this writer replaced; nil in files from
    /// before it existed.
    public var writeSequence: Int?
    /// A random id the agent draws at each launch: a snapshot from another
    /// launch answers a pending press even when numbering started again.
    public var writerId: String?

    public init(
        schemaVersion: Int = UsageSnapshot.currentSchemaVersion,
        writtenAt: Date,
        providers: [ProviderUsage],
        writeSequence: Int? = nil,
        writerId: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.writtenAt = writtenAt
        self.providers = providers
        self.writeSequence = writeSequence
        self.writerId = writerId
    }

    /// Which write this is: the writer and its number.
    public var mark: SnapshotMark {
        SnapshotMark(writer: writerId ?? "", sequence: writeSequence ?? 0)
    }
}

extension ProviderUsage {
    /// The error line the widget shows for this provider, if any.
    public var displayedError: String? {
        error ?? (status == .error ? "Unknown error" : nil)
    }
}

extension UsageSnapshot {
    public func provider(_ id: String) -> ProviderUsage? {
        providers.first { $0.provider == id }
    }
}

public struct SnapshotMark: Equatable, Sendable {
    public var writer: String
    public var sequence: Int

    public init(writer: String, sequence: Int) {
        self.writer = writer
        self.sequence = sequence
    }
}

/// One usage source, for example every cswap-managed account.
public struct ProviderUsage: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case error
    }

    /// Provider id: "claude" or "codex".
    public var provider: String
    /// Where the numbers came from, for example "cswap-list".
    public var source: String
    public var status: Status
    /// A short plain reason when `status` is `.error`, otherwise nil.
    public var error: String?
    /// On error these are the last good accounts, each with its own `fetchedAt`.
    public var accounts: [AccountUsage]
    /// Provider-specific data (plan, reset credits, ...); empty when a
    /// provider has none.
    public var extras: [String: JSONValue]
    /// Why collecting failed while the numbers are still good (a failed
    /// Codex app-server call beside a fresh rollout). For the status window
    /// and the logs; the widget does not draw it and it never asks for a
    /// reload.
    public var collectorError: String?
    /// Kept in the snapshot but not shown (Show Codex off): the widget, the
    /// reload fingerprint and the timeline treat the block as absent, and a
    /// restart can still start from its numbers.
    public var hidden = false

    public init(
        provider: String,
        source: String,
        status: Status,
        error: String? = nil,
        accounts: [AccountUsage],
        extras: [String: JSONValue] = [:],
        collectorError: String? = nil
    ) {
        self.provider = provider
        self.source = source
        self.status = status
        self.error = error
        self.accounts = accounts
        self.extras = extras
        self.collectorError = collectorError
    }
}

public struct AccountUsage: Codable, Equatable, Sendable {
    /// Whether the numbers are current. Additive to schema 1: a snapshot
    /// without it reads as `.ok`.
    public enum Status: String, Codable, Sendable {
        /// Current numbers.
        case ok
        /// Only a new login fixes it.
        case reloginRequired = "relogin_required"
        /// No numbers at all.
        case unavailable
        /// The current fetch failed; the windows are the last known numbers.
        case stale

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unavailable
        }
    }

    /// Stable id within the provider. For cswap this is the slot number.
    public var id: String
    /// What the widget shows: the alias when set, otherwise the email.
    public var label: String
    public var active: Bool
    /// When these numbers were measured, or nil when unknown. For last known
    /// numbers this is when they were last good, not when the fetch failed.
    public var fetchedAt: Date?
    public var windows: [UsageWindow]
    public var status: Status
    /// A short plain reason when `status` is not `.ok`, for example "Log in again".
    public var statusNote: String?
    /// How old the numbers were when the snapshot was written, measured on
    /// the agent's continuous clock; nil when only `fetchedAt` is known.
    public var ageSeconds: Double?

    public init(
        id: String, label: String, active: Bool, fetchedAt: Date?, windows: [UsageWindow],
        status: Status = .ok, statusNote: String? = nil
    ) {
        self.id = id
        self.label = label
        self.active = active
        self.fetchedAt = fetchedAt
        self.windows = windows
        self.status = status
        self.statusNote = statusNote
    }
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A short rolling window (Claude's 5 hour limit).
        case session
        /// A weekly window shared by every model.
        case weekly
        /// A weekly window that applies to one model only.
        case model
        /// Pay-as-you-go spend against a monthly limit.
        case spend
    }

    public var kind: Kind
    /// Short display name: "5h", "7d", or the model name.
    public var name: String
    /// Zero when the length is unknown (spend).
    public var windowSeconds: Int
    /// Percent used as reported, 0 to `UsageWindow.maxPct`. Can exceed 100;
    /// views clamp the bar. Nil when the source gave no usable number.
    public var usedPct: Double?
    public var resetsAt: Date?
    /// Where usage "on schedule" would be now (weekly and model windows).
    public var expectedPct: Double?
    public var aheadOfPace: Bool?
    /// Spend only: amount used, the limit, and the ISO currency code.
    public var amount: Double?
    public var limit: Double?
    public var currency: String?

    /// Percents above this are treated as unknown, not as usage.
    public static let maxPct = 10_000.0

    public init(
        kind: Kind,
        name: String,
        windowSeconds: Int,
        usedPct: Double?,
        resetsAt: Date? = nil,
        expectedPct: Double? = nil,
        aheadOfPace: Bool? = nil,
        amount: Double? = nil,
        limit: Double? = nil,
        currency: String? = nil
    ) {
        self.kind = kind
        self.name = name
        self.windowSeconds = windowSeconds
        self.usedPct = usedPct
        self.resetsAt = resetsAt
        self.expectedPct = expectedPct
        self.aheadOfPace = aheadOfPace
        self.amount = amount
        self.limit = limit
        self.currency = currency
    }
}

/// A minimal JSON value, so `extras` can carry provider-specific data.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}
