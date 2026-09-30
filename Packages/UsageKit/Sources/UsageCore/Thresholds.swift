import Foundation

/// Colour band of a usage percentage.
public enum UsageLevel: String, Codable, Sendable {
    /// Below 70: green.
    case ok
    /// 70 to below 90: yellow.
    case warn
    /// 90 to below 100: red.
    case hot
    /// 100 and above: red, with the "(!)" marker.
    case over
    /// No usable number: no bar, "?" text.
    case unknown
}

/// The same bands as cswap's terminal dashboard and menu bar
/// (`WARN_PCT` and `CRIT_PCT` in `claude_swap/tui/theme.py`), so every
/// surface agrees on when a bar turns yellow or red.
public enum UsageThresholds {
    public static let warnPct = 70.0
    public static let critPct = 90.0
    public static let overPct = 100.0

    public static func level(for pct: Double) -> UsageLevel {
        if pct >= overPct { return .over }
        if pct >= critPct { return .hot }
        if pct >= warnPct { return .warn }
        return .ok
    }
}
