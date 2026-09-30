import Foundation

// Optional fields are written as explicit `null` rather than left out, so
// every reader sees the same keys whatever the data (for example
// `"resetsAt": null` on an idle 5h window).

extension ProviderUsage {
    enum CodingKeys: String, CodingKey {
        case provider, source, status, error, accounts, extras, collectorError, hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        source = try c.decode(String.self, forKey: .source)
        status = try c.decode(Status.self, forKey: .status)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        accounts = try c.decode([AccountUsage].self, forKey: .accounts)
        extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
        collectorError = try c.decodeIfPresent(String.self, forKey: .collectorError)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(source, forKey: .source)
        try c.encode(status, forKey: .status)
        try c.encode(error, forKey: .error)
        try c.encode(accounts, forKey: .accounts)
        try c.encode(extras, forKey: .extras)
        try c.encode(collectorError, forKey: .collectorError)
        try c.encode(hidden, forKey: .hidden)
    }
}

extension AccountUsage {
    enum CodingKeys: String, CodingKey {
        case id, label, active, fetchedAt, windows, status, statusNote, ageSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        active = try c.decode(Bool.self, forKey: .active)
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
        windows = try c.decode([UsageWindow].self, forKey: .windows)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .ok
        statusNote = try c.decodeIfPresent(String.self, forKey: .statusNote)
        ageSeconds = try c.decodeIfPresent(Double.self, forKey: .ageSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(active, forKey: .active)
        try c.encode(fetchedAt, forKey: .fetchedAt)
        try c.encode(windows, forKey: .windows)
        try c.encode(status, forKey: .status)
        try c.encode(statusNote, forKey: .statusNote)
        try c.encode(ageSeconds, forKey: .ageSeconds)
    }
}

extension UsageWindow {
    enum CodingKeys: String, CodingKey {
        case kind, name, windowSeconds, usedPct, resetsAt, expectedPct, aheadOfPace, amount, limit, currency
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(windowSeconds, forKey: .windowSeconds)
        try c.encode(usedPct, forKey: .usedPct)
        try c.encode(resetsAt, forKey: .resetsAt)
        try c.encode(expectedPct, forKey: .expectedPct)
        try c.encode(aheadOfPace, forKey: .aheadOfPace)
        try c.encode(amount, forKey: .amount)
        try c.encode(limit, forKey: .limit)
        try c.encode(currency, forKey: .currency)
    }
}
