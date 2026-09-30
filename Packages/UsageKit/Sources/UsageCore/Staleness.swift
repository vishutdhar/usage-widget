import Foundation

/// How old a provider's numbers may get before they count as stale: the
/// widget dims them, the timeline plans the moment, and a Codex account
/// turns stale. Each line matches how often the provider is refreshed.
public enum Staleness {
    /// cswap refreshes every few minutes.
    public static let dimAfter: TimeInterval = 2 * 3600
    /// Codex is asked every three hours while it is idle, so its line sits
    /// past that: numbers do not flip stale and back between answers.
    public static let codexLine: TimeInterval = 4 * 3600

    public static func line(for provider: String) -> TimeInterval {
        provider == "codex" ? codexLine : dimAfter
    }

    /// An account's numbers at `date`: by the age the agent kept on its
    /// continuous clock plus the time since the snapshot was written
    /// (never younger than at the write), when it kept one; otherwise by
    /// the measurement time.
    public static func isDimmed(_ account: AccountUsage, writtenAt: Date?, at date: Date, provider: String) -> Bool {
        guard let age = account.ageSeconds, let writtenAt else {
            return isDimmed(fetchedAt: account.fetchedAt, at: date, provider: provider)
        }
        let total = age + max(0, date.timeIntervalSince(writtenAt))
        return total.isFinite && total > line(for: provider)
    }

    /// The moment an account's numbers pass the line, for the timeline.
    public static func dimMoment(_ account: AccountUsage, writtenAt: Date, provider: String) -> Date? {
        if let age = account.ageSeconds { return writtenAt.addingTimeInterval(line(for: provider) - age + 1) }
        return account.fetchedAt.map { $0.addingTimeInterval(line(for: provider) + 1) }
    }

    public static func isDimmed(fetchedAt: Date?, at date: Date, provider: String) -> Bool {
        guard let fetchedAt else { return false }
        let age = date.timeIntervalSince(fetchedAt)
        return age.isFinite && age > line(for: provider)
    }
}
