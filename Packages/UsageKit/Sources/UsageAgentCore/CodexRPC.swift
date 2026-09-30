import Foundation

/// The only messages the agent ever sends to `codex app-server`.
///
/// Every outgoing line is built here, and anything outside the allowlist
/// throws. In particular `account/rateLimitResetCredit/consume`, which
/// would spend a banked reset, cannot be encoded at all.
public enum CodexRPC {
    /// The handshake request and the one read.
    public static let allowedRequests: Set<String> = ["initialize", "account/rateLimits/read"]
    /// The handshake's closing notification.
    public static let allowedNotifications: Set<String> = ["initialized"]

    public enum Refusal: Error, Equatable, Sendable {
        case forbidden(String)
    }

    /// One JSON line for a request.
    public static func request(id: Int, method: String, params: [String: Any]? = nil) throws(Refusal) -> Data {
        guard allowedRequests.contains(method) else { throw .forbidden(method) }
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        return line(message)
    }

    /// One JSON line for a notification.
    public static func notification(method: String) throws(Refusal) -> Data {
        guard allowedNotifications.contains(method) else { throw .forbidden(method) }
        return line(["method": method])
    }

    private static func line(_ message: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
