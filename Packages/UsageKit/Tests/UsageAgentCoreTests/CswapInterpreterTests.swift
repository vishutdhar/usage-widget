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

    /// A run with `--fresh` that this cswap refused, and nothing else:
    /// argparse's own refusal, exit status 2 and a stderr line
    /// "error: unrecognized arguments:" whose arguments include --fresh.
    /// Every other exit, text or stream is the ordinary error path.
    func testOnlyArgparsesRefusalOfFreshCounts() {
        func run(_ code: Int32, out: String = "", err: String = "") -> Result<RunOutput, RunFailure> {
            .success(RunOutput(exitCode: code, stdout: Data(out.utf8), stderr: Data(err.utf8)))
        }
        let argparse = "usage: cswap <command> [args] [options]\ncswap: error: unrecognized arguments: --fresh\n"
        XCTAssertTrue(CswapInterpreter.rejectsFresh(run(2, err: argparse)), "the installed cswap, verbatim")
        XCTAssertTrue(CswapInterpreter.rejectsFresh(run(2, err: "cswap: error: unrecognized arguments: --json2 --fresh\n")),
                      "--fresh among several")

        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(1, err: "RuntimeError: --fresh failed: network unreachable\n")),
                       "a failure that names --fresh")
        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(2, err: "cswap: error: unrecognized arguments: --freshness\n")),
                       "unrecognized arguments that do not include --fresh")
        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(2, err: "cswap: error: argument --fresh: not allowed with argument --token-status\n")),
                       "an argument conflict")
        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(2, out: argparse)), "argparse's refusal goes to stderr")
        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(1, err: argparse)), "exit status 1")
        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(0, out: "{}", err: argparse)), "a zero exit")
        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(2, err: "unrecognized arguments: --fresh\n")), "not argparse's error line")
        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(2, err: "Error: No such option: --fresh\n")))
        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(1, err: "Traceback (most recent call last):\nRuntimeError: keychain locked\n")))
        XCTAssertFalse(CswapInterpreter.rejectsFresh(run(1, out: #"{"schemaVersion": 1, "error": {"type": "X", "message": "No accounts yet"}}"#)))
        XCTAssertFalse(CswapInterpreter.rejectsFresh(.failure(.timedOut(50))))
        XCTAssertFalse(CswapInterpreter.rejectsFresh(.failure(.notFound)))
    }

    func testMultilineMessageBecomesOneLine() throws {
        let envelope = Data(#"{"schemaVersion": 1, "error": {"type": "X", "message": "first\nsecond"}}"#.utf8)
        XCTAssertEqual(reason(.success(RunOutput(exitCode: 1, stdout: envelope))), "cswap: first second")
    }
}
