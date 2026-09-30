import XCTest
@testable import UsageAgentCore

final class CodexRPCTests: XCTestCase {
    func lines(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Every client request in the generated protocol schema: only the
    /// handshake and the rate limit read can be encoded.
    func testOnlyTheHandshakeAndTheReadCanBeEncoded() throws {
        let methods = try lines("codex-client-methods")
        XCTAssertEqual(methods.count, 99)
        var encoded: [String] = []
        for method in methods {
            do {
                _ = try CodexRPC.request(id: 1, method: method)
                encoded.append(method)
            } catch {
                XCTAssertEqual(error, .forbidden(method))
            }
        }
        XCTAssertEqual(encoded, ["account/rateLimits/read", "initialize"])
    }

    func testTheResetCreditConsumeMethodCannotBeSent() {
        XCTAssertThrowsError(try CodexRPC.request(id: 7, method: "account/rateLimitResetCredit/consume")) { error in
            XCTAssertEqual(error as? CodexRPC.Refusal, .forbidden("account/rateLimitResetCredit/consume"))
        }
        XCTAssertThrowsError(try CodexRPC.notification(method: "account/rateLimitResetCredit/consume"))
    }

    func testTheOnlyNotificationIsInitialized() throws {
        XCTAssertEqual(try lines("codex-client-notifications"), ["initialized"])
        XCTAssertNoThrow(try CodexRPC.notification(method: "initialized"))
        XCTAssertThrowsError(try CodexRPC.notification(method: "initialize"))
        XCTAssertThrowsError(try CodexRPC.notification(method: "account/rateLimits/read"))
    }

    func testEncodedLines() throws {
        let initialize = try CodexRPC.request(id: 1, method: "initialize",
                                              params: ["clientInfo": ["name": "usage-widget", "version": "1.0"]])
        XCTAssertEqual(initialize.last, UInt8(ascii: "\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: initialize) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 1)
        XCTAssertEqual(object["method"] as? String, "initialize")
        XCTAssertEqual((object["params"] as? [String: Any])?["clientInfo"] as? [String: String],
                       ["name": "usage-widget", "version": "1.0"])

        let read = try XCTUnwrap(JSONSerialization.jsonObject(with: CodexRPC.request(id: 2, method: "account/rateLimits/read"))
                                    as? [String: Any])
        XCTAssertEqual(Set(read.keys), ["id", "method"], "params are null, so left out")

        let note = try XCTUnwrap(JSONSerialization.jsonObject(with: CodexRPC.notification(method: "initialized"))
                                    as? [String: Any])
        XCTAssertEqual(Set(note.keys), ["method"])
    }
}
