import XCTest
import UsageCore
@testable import UsageAgentCore

final class CswapInterpreterTests: XCTestCase {
    func reason(_ result: Result<RunOutput, RunFailure>) -> String? {
        if case .failure(let failure) = CswapInterpreter.interpret(result) { return failure.reason }
        return nil
    }

    func testSuccessMapsAccounts() throws {
        let result = CswapInterpreter.interpret(.success(RunOutput(exitCode: 0, stdout: listJSON([("1", true, 20)]))))
        let accounts = try result.get()
        XCTAssertEqual(accounts.map(\.id), ["1"])
        XCTAssertEqual(try accounts[at: 0].windows.map(\.name), ["5h", "7d"])
    }

    func testPlainReasons() {
        XCTAssertEqual(reason(.failure(.notFound)), "cswap not found")
        XCTAssertEqual(reason(.failure(.timedOut(50))), "cswap did not answer within 50 s")
        XCTAssertEqual(reason(.failure(.launchFailed("Permission denied"))), "cswap could not start: Permission denied")
        XCTAssertEqual(reason(.failure(.outputTooLarge)), "cswap output too large")
        XCTAssertEqual(reason(.success(RunOutput(exitCode: 2, stdout: Data("Traceback".utf8)))), "cswap exited with code 2")
        XCTAssertEqual(reason(.success(RunOutput(exitCode: 0, stdout: Data("oops".utf8)))), "cswap output could not be read")
        XCTAssertEqual(reason(.success(RunOutput(exitCode: 0, stdout: listJSON([], schema: 2)))),
                       "cswap output format 2 is not supported")
    }

    func testErrorEnvelopeMessageIsUsedWhateverTheExitCode() {
        let envelope = Data(#"{"schemaVersion": 1, "error": {"type": "X", "message": "No accounts yet"}}"#.utf8)
        XCTAssertEqual(reason(.success(RunOutput(exitCode: 1, stdout: envelope))), "cswap: No accounts yet")
        XCTAssertEqual(reason(.success(RunOutput(exitCode: 0, stdout: envelope))), "cswap: No accounts yet")
    }

    func testEmailsInReasonsAreMasked() {
        let envelope = Data(#"{"schemaVersion": 1, "error": {"type": "X", "message": "No login for someone@example.com"}}"#.utf8)
        XCTAssertEqual(reason(.success(RunOutput(exitCode: 1, stdout: envelope))), "cswap: No login for som***@***.com")
    }

    func testLongReasonsAreShortened() throws {
        let long = String(repeating: "x", count: 500)
        let envelope = Data(#"{"schemaVersion": 1, "error": {"type": "X", "message": "\#(long)"}}"#.utf8)
        let text = try XCTUnwrap(reason(.success(RunOutput(exitCode: 1, stdout: envelope))))
        XCTAssertLessThanOrEqual(text.count, CswapInterpreter.maxReasonLength)
        XCTAssertTrue(text.hasSuffix("…"))
    }

    func testMultilineMessageBecomesOneLine() throws {
        let envelope = Data(#"{"schemaVersion": 1, "error": {"type": "X", "message": "first\nsecond"}}"#.utf8)
        XCTAssertEqual(reason(.success(RunOutput(exitCode: 1, stdout: envelope))), "cswap: first second")
    }
}
