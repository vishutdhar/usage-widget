import Foundation

public enum CswapListError: Error, Equatable, Sendable {
    /// Not JSON, or not the `cswap list --json` shape.
    case unreadable
    /// A schema version this build does not understand.
    case unsupportedSchema(Int)
    /// cswap's own error envelope: `{"error": {"message": ...}}`.
    case reported(String)
}

/// Maps `cswap list --json` (schemaVersion 1) into snapshot accounts.
///
/// Mirrors the menu bar's reading of the same data: windows in the order
/// 5h, 7d, each named per-model window, then spend; a scoped window without
/// a name is skipped; an account whose usage is unavailable shows cswap's
/// last good usage, with that usage's own measurement time. A percent that
/// is missing, not a number, infinite, or above `UsageWindow.maxPct` is
/// unknown; a negative one is 0.
public enum CswapListMapper {
    public static let provider = "claude"
    public static let source = "cswap-list"
    public static let supportedSchemaVersion = 1

    public static func accounts(from data: Data) throws(CswapListError) -> [AccountUsage] {
        let prepared = try JSONPreparer.prepare(data)
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: prepared) as? [String: Any] else {
                throw CswapListError.unreadable
            }
            root = object
        } catch {
            throw .unreadable
        }

        if let envelope = root["error"] as? [String: Any] {
            let message = (envelope["message"] as? String) ?? (envelope["type"] as? String) ?? "unknown error"
            throw .reported(message)
        }
        if let version = root["schemaVersion"] as? Int, version != supportedSchemaVersion {
            throw .unsupportedSchema(version)
        }
        guard let rows = root["accounts"] as? [[String: Any]] else { throw .unreadable }

        let activeNumber = root["activeAccountNumber"] as? Int
        return rows.compactMap { account(from: $0, activeNumber: activeNumber) }
    }

    private static func account(from row: [String: Any], activeNumber: Int?) -> AccountUsage? {
        guard let number = row["number"] as? Int else { return nil }
        let email = (row["email"] as? String) ?? ""
        let alias = ((row["alias"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let active = (row["active"] as? Bool) ?? (activeNumber == number)
        let cswapStatus = (row["usageStatus"] as? String) ?? "ok"

        var usage = row["usage"] as? [String: Any]
        var fetched = (row["usageFetchedAt"] as? String).flatMap(ISODate.parse)
        var lastKnown = false
        if usage == nil, let lastGood = row["lastGoodUsage"] as? [String: Any] {
            usage = lastGood
            fetched = (row["lastGoodFetchedAt"] as? String).flatMap(ISODate.parse)
            lastKnown = true
        }

        let (status, note) = accountStatus(
            cswapStatus: cswapStatus, hasUsage: usage != nil, lastKnown: lastKnown,
            usageError: row["usageError"] as? String
        )
        return AccountUsage(
            id: String(number),
            label: alias.isEmpty ? email : alias,
            active: active,
            fetchedAt: usage == nil ? nil : fetched,
            windows: usage.map(windows(from:)) ?? [],
            status: status,
            statusNote: note
        )
    }

    /// cswap's `usageStatus` (json_output.py `usage_fields`) as an account
    /// status and a short note for the widget.
    static func accountStatus(
        cswapStatus: String, hasUsage: Bool, lastKnown: Bool, usageError: String?
    ) -> (AccountUsage.Status, String?) {
        if cswapStatus == "ok", hasUsage, !lastKnown { return (.ok, nil) }
        let note: String
        switch cswapStatus {
        case "relogin_required": return (.reloginRequired, "Log in again")
        case "no_credentials": return (.reloginRequired, "No saved login")
        case "token_expired": note = "Token expired"
        case "keychain_unavailable": note = "Keychain locked"
        case "foreign_credential": note = "Signed in as another account"
        case "api_key": note = "API key, no plan limits"
        case "unavailable":
            note = usageError.map { "Usage unavailable (\(Redactor.redactEmails($0)))" } ?? "Usage unavailable"
        default: note = "Usage unavailable"
        }
        return (hasUsage ? .stale : .unavailable, note)
    }

    private static func windows(from usage: [String: Any]) -> [UsageWindow] {
        var result: [UsageWindow] = []
        if let five = window(usage["fiveHour"], seconds: WindowLength.fiveHours, modelName: nil) {
            result.append(five)
        }
        if let seven = window(usage["sevenDay"], seconds: WindowLength.sevenDays, modelName: nil) {
            result.append(seven)
        }
        for scoped in (usage["scoped"] as? [[String: Any]]) ?? [] {
            guard let name = scoped["name"] as? String, !name.isEmpty else { continue }
            if let model = window(scoped, seconds: WindowLength.sevenDays, modelName: name) {
                result.append(model)
            }
        }
        if let raw = usage["spend"] as? [String: Any] {
            result.append(UsageWindow(
                kind: .spend,
                name: "Spend",
                windowSeconds: 0,
                usedPct: percent(raw["pct"]),
                resetsAt: (raw["resetsAt"] as? String).flatMap(ISODate.parse),
                amount: finite(raw["used"]),
                limit: finite(raw["limit"]),
                currency: raw["currency"] as? String
            ))
        }
        return result
    }

    private static func window(_ value: Any?, seconds: Int, modelName: String?) -> UsageWindow? {
        guard let raw = value as? [String: Any] else { return nil }
        let kind = UsageWindow.Kind.classify(windowSeconds: seconds, modelScoped: modelName != nil)
        return UsageWindow(
            kind: kind,
            name: modelName ?? WindowLength.shortName(seconds: seconds),
            windowSeconds: seconds,
            usedPct: percent(raw["pct"]),
            resetsAt: (raw["resetsAt"] as? String).flatMap(ISODate.parse),
            expectedPct: kind == .session ? nil : finite(raw["expectedPct"]),
            aheadOfPace: kind == .session ? nil : raw["aheadOfPace"] as? Bool
        )
    }

    /// A usable percent: finite and at most `maxPct`, negatives read as 0.
    static func percent(_ value: Any?) -> Double? {
        guard let pct = finite(value), pct <= UsageWindow.maxPct else { return nil }
        return max(0, pct)
    }

    /// A finite JSON number, but not a JSON boolean (NSNumber bridges both).
    static func finite(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
}

/// Makes `cswap list --json` output safe for a strict JSON parser, in one
/// linear pass over the bytes.
///
/// Python's `json.dumps` writes NaN, Infinity and -Infinity as bare tokens,
/// which JSON does not allow; outside strings they become `null`. So does a
/// number a Double cannot hold (1e309) or one longer than 40 digits: that
/// window reads as unknown and the rest of the reading survives. Nothing
/// else is relaxed: no comments, no hex, and no trailing commas
/// (Foundation's parser would accept those, so they are rejected here).
/// A key repeated within one object is rejected, since `json.dumps` of a
/// dict never produces one. Keys are compared as their unescaped UTF-8
/// bytes, as JSON and Python do, so "a" repeats "a" but a precomposed
/// and a decomposed "é" are different keys.
enum JSONPreparer {
    /// One open object or array. An object's keys are kept here and changed
    /// in place, so each key costs one hash insert.
    private struct Level {
        var isObject: Bool
        var expectingKey: Bool
        var keys: Set<[UInt8]> = []
    }

    static let maxDigits = 40

    static func prepare(_ data: Data) throws(CswapListError) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        let result: Result<Void, CswapListError> = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            do {
                try scan(bytes, into: &out)
                return .success(())
            } catch let error as CswapListError {
                return .failure(error)
            } catch {
                return .failure(.unreadable)
            }
        }
        try result.get()
        return Data(out)
    }

    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
    private static let null = Array("null".utf8)

    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>, into out: inout [UInt8]) throws(CswapListError) {
        var levels: [Level] = []
        var lastSignificant: UInt8 = 0
        var i = 0
        let n = bytes.count

        func matches(_ word: StaticString, at index: Int) -> Bool {
            let count = word.utf8CodeUnitCount
            guard index + count <= n else { return false }
            return word.withUTF8Buffer { w in
                for k in 0..<count where bytes[index + k] != w[k] { return false }
                return true
            }
        }

        while i < n {
            let b = bytes[i]
            switch b {
            case quote:
                let start = i
                i += 1
                var escaped = false
                while i < n, bytes[i] != quote {
                    if bytes[i] == backslash { escaped = true; i += 2 } else { i += 1 }
                }
                guard i < n else { throw .unreadable }
                out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start...i]))
                if let top = levels.indices.last, levels[top].isObject, levels[top].expectingKey {
                    let body = UnsafeBufferPointer(rebasing: bytes[(start + 1)..<i])
                    let key = escaped ? try unescape(body) : Array(body)
                    guard levels[top].keys.insert(key).inserted else { throw .unreadable }
                    levels[top].expectingKey = false
                }
                lastSignificant = quote
                i += 1
                continue
            case UInt8(ascii: "{"):
                levels.append(Level(isObject: true, expectingKey: true))
            case UInt8(ascii: "["):
                levels.append(Level(isObject: false, expectingKey: false))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard lastSignificant != UInt8(ascii: ",") else { throw .unreadable }
                if !levels.isEmpty { levels.removeLast() }
            case UInt8(ascii: ","):
                if let top = levels.indices.last, levels[top].isObject { levels[top].expectingKey = true }
            case UInt8(ascii: "N") where matches("NaN", at: i):
                out.append(contentsOf: null)
                lastSignificant = UInt8(ascii: "l")
                i += 3
                continue
            case UInt8(ascii: "I") where matches("Infinity", at: i):
                out.append(contentsOf: null)
                lastSignificant = UInt8(ascii: "l")
                i += 8
                continue
            case UInt8(ascii: "-") where matches("-Infinity", at: i):
                out.append(contentsOf: null)
                lastSignificant = UInt8(ascii: "l")
                i += 9
                continue
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                let start = i
                var digits = 0
                var inExponent = false
                while i < n {
                    let c = bytes[i]
                    if c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") {
                        if !inExponent { digits += 1 }
                    } else if c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                        inExponent = true
                    } else if !(c == UInt8(ascii: "-") || c == UInt8(ascii: "+") || c == UInt8(ascii: ".")) {
                        break
                    }
                    i += 1
                }
                let token = UnsafeBufferPointer(rebasing: bytes[start..<i])
                let value = Double(String(decoding: token, as: UTF8.self))
                if digits > maxDigits || (value.map { !$0.isFinite } ?? false) {
                    out.append(contentsOf: null)
                } else {
                    out.append(contentsOf: token)  // a malformed number is left for the parser to reject
                }
                lastSignificant = UInt8(ascii: "0")
                continue
            default:
                break
            }
            if b != UInt8(ascii: " "), b != UInt8(ascii: "\n"), b != UInt8(ascii: "\r"), b != UInt8(ascii: "\t") {
                lastSignificant = b
            }
            out.append(b)
            i += 1
        }
    }

    /// The UTF-8 bytes a JSON string body stands for. A lone surrogate from
    /// \u escapes is kept in its three byte form, so distinct escapes stay
    /// distinct keys.
    private static func unescape(_ body: UnsafeBufferPointer<UInt8>) throws(CswapListError) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        var i = 0
        func hex4(_ at: Int) throws(CswapListError) -> UInt32 {
            guard at + 4 <= body.count else { throw .unreadable }
            var value: UInt32 = 0
            for k in 0..<4 {
                let c = body[at + k]
                let digit: UInt32
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(c - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(c - UInt8(ascii: "A") + 10)
                default: throw .unreadable
                }
                value = value << 4 | digit
            }
            return value
        }
        func append(scalar v: UInt32) {
            switch v {
            case 0..<0x80:
                out.append(UInt8(v))
            case 0x80..<0x800:
                out.append(UInt8(0xC0 | v >> 6)); out.append(UInt8(0x80 | v & 0x3F))
            case 0x800..<0x10000:
                out.append(UInt8(0xE0 | v >> 12)); out.append(UInt8(0x80 | v >> 6 & 0x3F)); out.append(UInt8(0x80 | v & 0x3F))
            default:
                out.append(UInt8(0xF0 | v >> 18)); out.append(UInt8(0x80 | v >> 12 & 0x3F))
                out.append(UInt8(0x80 | v >> 6 & 0x3F)); out.append(UInt8(0x80 | v & 0x3F))
            }
        }
        while i < body.count {
            let c = body[i]
            guard c == backslash else {
                out.append(c)
                i += 1
                continue
            }
            guard i + 1 < body.count else { throw .unreadable }
            let e = body[i + 1]
            i += 2
            switch e {
            case quote, backslash, UInt8(ascii: "/"): out.append(e)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var v = try hex4(i)
                i += 4
                if (0xD800...0xDBFF).contains(v), i + 6 <= body.count, body[i] == backslash, body[i + 1] == UInt8(ascii: "u") {
                    let low = try hex4(i + 2)
                    if (0xDC00...0xDFFF).contains(low) {
                        v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                        i += 6
                    }
                }
                append(scalar: v)
            default:
                throw .unreadable
            }
        }
        return out
    }
}
