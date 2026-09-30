import XCTest
@testable import UsageCore

final class StrictJSONTests: XCTestCase {
    func parse(_ text: String) throws -> Any {
        let prepared = try JSONPreparer.prepare(Data(text.utf8))
        return try JSONSerialization.jsonObject(with: prepared)
    }

    func testPythonsBareNonFiniteTokensBecomeNull() throws {
        let object = try XCTUnwrap(parse(#"{"a": NaN, "b": [Infinity, -Infinity], "c": 1}"#) as? [String: Any])
        XCTAssertTrue(object["a"] is NSNull)
        XCTAssertEqual((object["b"] as? [Any])?.count, 2)
        XCTAssertTrue((object["b"] as? [Any])?.allSatisfy { $0 is NSNull } ?? false)
        XCTAssertEqual(object["c"] as? Int, 1)
    }

    func testTheSameWordsInsideStringsAreLeftAlone() throws {
        let object = try XCTUnwrap(parse(#"{"alias": "NaN and -Infinity", "q": "say \"NaN\""}"#) as? [String: Any])
        XCTAssertEqual(object["alias"] as? String, "NaN and -Infinity")
        XCTAssertEqual(object["q"] as? String, #"say "NaN""#)
    }

    func testDuplicateKeysAreMalformed() {
        // json.dumps of a dict can never repeat a key, so a repeat means the
        // output is not what cswap wrote.
        for text in [#"{"number": 1, "number": 2}"#, #"{"a": 1, "\u0061": 2}"#,
                     #"{"accounts": [{"x": {"k": 1, "k": 2}}]}"#] {
            XCTAssertThrowsError(try JSONPreparer.prepare(Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? CswapListError, .unreadable, text)
            }
        }
    }

    func testTheSameKeyInSeparateObjectsIsFine() throws {
        XCTAssertNoThrow(try parse(#"[{"a": 1, "b": {"a": 2}}, {"a": 3}]"#))
    }

    func testJSON5ExtrasAreRejected() {
        for text in [#"{"a": 0x10}"#, "{\"a\": 1, // note\n}", #"{"a": 1,}"#, "{a: 1}", #"{"a": +1}"#] {
            XCTAssertThrowsError(try parse(text), text)
        }
    }

    func testMapperRejectsDuplicateKeysAndJSON5() {
        let duplicate = #"{"schemaVersion": 1, "accounts": [{"number": 1, "number": 2, "email": "a@example.com"}]}"#
        let json5 = #"{"schemaVersion": 1, "accounts": [], /* note */}"#
        for text in [duplicate, json5] {
            XCTAssertThrowsError(try CswapListMapper.accounts(from: Data(text.utf8)), text) { error in
                XCTAssertEqual(error as? CswapListError, .unreadable, text)
            }
        }
    }

    /// Key identity is the unescaped UTF-8 bytes, as in JSON and Python:
    /// a precomposed é and an e with a combining accent are different keys.
    func testCanonicallyEquivalentKeysAreDistinct() throws {
        let precomposed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(precomposed, decomposed, "Swift strings call these equal")
        let text = "{\"" + precomposed + "\": 1, \"" + decomposed + "\": 2}"
        let object = try XCTUnwrap(parse(text) as? NSDictionary)
        XCTAssertEqual(object.count, 2)
    }

    /// The pass is linear: 2 MiB holding 150,000 unique keys, in a debug build.
    func testALargeObjectIsPreparedQuickly() throws {
        var text = "{"
        text.reserveCapacity(2_200_000)
        for i in 0..<150_000 {
            if i > 0 { text += "," }
            text += "\"key" + String(i) + "\":0"
        }
        text += "}"
        let data = Data(text.utf8)
        XCTAssertGreaterThan(data.count, 1_900_000)
        let start = Date()
        _ = try JSONPreparer.prepare(data)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertLessThan(seconds, 1.0, "took \(seconds) s")
    }

    func testNumbersJSONCannotHoldBecomeNull() throws {
        let long = String(repeating: "9", count: 400)
        let object = try XCTUnwrap(parse("[1e309, -1e309, " + long + ", 12.5, -3, 1e20, 0.5e-3]") as? [Any])
        XCTAssertTrue(object[0] is NSNull, "1e309 overflows a Double")
        XCTAssertTrue(object[1] is NSNull)
        XCTAssertTrue(object[2] is NSNull, "a 400 digit integer")
        XCTAssertEqual(object[3] as? Double, 12.5)
        XCTAssertEqual(object[4] as? Int, -3)
        XCTAssertEqual(object[5] as? Double, 1e20)
        XCTAssertEqual(object[6] as? Double, 0.0005)
    }

    /// Past 40 digits a number is refused even when a Double could hold it.
    func testLongNumbersAreRefusedAtFortyOneDigits() throws {
        let fortyOne = String(repeating: "1", count: 41)
        let longFraction = "12." + String(repeating: "5", count: 39)
        let forty = String(repeating: "1", count: 40)
        let object = try XCTUnwrap(parse("[" + fortyOne + ", " + longFraction + ", " + forty + "]") as? [Any])
        XCTAssertTrue(object[0] is NSNull, "41 digits")
        XCTAssertTrue(object[1] is NSNull, "41 digits across the decimal point")
        XCTAssertFalse(object[2] is NSNull, "40 digits is still a number")
    }

    func testAnOverflowingPercentOnlyAffectsItsOwnWindow() throws {
        let long = String(repeating: "7", count: 400)
        let text = """
        {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
          {"number": 1, "email": "a1@example.com", "active": true, "usageStatus": "ok",
           "usage": {"fiveHour": {"pct": 1e309}, "sevenDay": {"pct": \(long)}}, "usageFetchedAt": "2026-09-27T10:00:00Z"},
          {"number": 2, "email": "a2@example.com", "active": false, "usageStatus": "ok",
           "usage": {"fiveHour": {"pct": 12.0}}, "usageFetchedAt": "2026-09-27T10:00:00Z"}]}
        """
        let accounts = try CswapListMapper.accounts(from: Data(text.utf8))
        XCTAssertEqual(accounts.map(\.id), ["1", "2"])
        XCTAssertEqual(try accounts[at: 0].windows.map(\.usedPct), [nil, nil], "shown as ? with no bar")
        XCTAssertEqual(try accounts[at: 1].windows.map(\.usedPct), [12])
    }
}
