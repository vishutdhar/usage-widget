import Foundation

public enum SnapshotBuilder {
    /// The next snapshot after one fetch of `provider`.
    ///
    /// Success replaces that provider's accounts and clears its error.
    /// Failure marks it `error` with `reason` and keeps its last good
    /// accounts, each with the `fetchedAt` it was measured at. Other
    /// providers pass through untouched.
    public static func updating(
        _ previous: UsageSnapshot?,
        provider: String,
        source: String,
        outcome: Result<[AccountUsage], FetchFailure>,
        now: Date
    ) -> UsageSnapshot {
        var providers = previous?.providers ?? []
        let index = providers.firstIndex { $0.provider == provider }
        let old = index.map { providers[$0] }

        let block: ProviderUsage
        switch outcome {
        case .success(let accounts):
            block = ProviderUsage(provider: provider, source: source, status: .ok, error: nil,
                                  accounts: accounts, extras: old?.extras ?? [:])
        case .failure(let failure):
            block = ProviderUsage(provider: provider, source: source, status: .error, error: failure.reason,
                                  accounts: old?.accounts ?? [], extras: old?.extras ?? [:])
        }

        if let index {
            providers[index] = block
        } else {
            providers.append(block)
        }
        return UsageSnapshot(writtenAt: now, providers: providers)
    }
}

public struct FetchFailure: Error, Equatable, Sendable {
    /// Short and plain, shown in the widget as is.
    public var reason: String
    public init(reason: String) { self.reason = reason }
}
