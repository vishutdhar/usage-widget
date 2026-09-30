import Foundation
import UsageCore

/// Turns one cswap run into accounts or a short plain reason.
public enum CswapInterpreter {
    public static let maxReasonLength = 120

    public static func interpret(_ result: Result<RunOutput, RunFailure>) -> Result<[AccountUsage], FetchFailure> {
        switch result {
        case .failure(let failure):
            return .failure(FetchFailure(reason: reason(for: failure)))
        case .success(let output):
            do {
                let accounts = try CswapListMapper.accounts(from: output.stdout)
                // A zero exit is part of success: a non-zero exit with
                // well-formed output still means cswap reported a problem.
                guard output.exitCode == 0 else {
                    return .failure(FetchFailure(reason: "cswap exited with code \(output.exitCode)"))
                }
                return .success(accounts)
            } catch {
                switch error {
                case .reported(let message):
                    return .failure(FetchFailure(reason: shorten("cswap: \(message)")))
                case .unsupportedSchema(let version):
                    return .failure(FetchFailure(reason: "cswap output format \(version) is not supported"))
                case .unreadable:
                    let reason = output.exitCode == 0
                        ? "cswap output could not be read"
                        : "cswap exited with code \(output.exitCode)"
                    return .failure(FetchFailure(reason: reason))
                }
            }
        }
    }

    static func reason(for failure: RunFailure) -> String {
        switch failure {
        case .notFound:
            return "cswap not found"
        case .timedOut(let seconds):
            return "cswap did not answer within \(Int(seconds)) s"
        case .launchFailed(let detail):
            return shorten("cswap could not start: \(detail)")
        case .outputTooLarge:
            return "cswap output too large"
        }
    }

    /// One line, at most `maxReasonLength` characters, emails masked.
    static func shorten(_ text: String) -> String {
        let oneLine = Redactor.redactEmails(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard oneLine.count > maxReasonLength else { return oneLine }
        return String(oneLine.prefix(maxReasonLength - 1)) + "…"
    }
}
