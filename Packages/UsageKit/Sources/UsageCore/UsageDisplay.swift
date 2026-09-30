import Foundation

public struct SpendFigures: Equatable, Sendable {
    public var amount: Double
    public var limit: Double
    public var currency: String

    public init(amount: Double, limit: Double, currency: String) {
        self.amount = amount
        self.limit = limit
        self.currency = currency
    }
}

/// One window as the widget draws it.
public struct WindowRow: Equatable, Sendable {
    public var label: String
    public var kind: UsageWindow.Kind
    /// Percent after rolling past a reset that has already happened.
    public var usedPct: Double
    /// Bar fill, clamped to 0...1.
    public var fraction: Double
    /// "22%", rounded the way cswap rounds (half to even).
    public var percentText: String
    public var level: UsageLevel
    /// Pace tick position in 0...1, or nil when no tick is drawn.
    public var paceFraction: Double?
    /// The next reset still in the future, or nil.
    public var resetsAt: Date?
    /// True at or over 100 percent: the "(!)" marker.
    public var overMarker: Bool
    public var aheadOfPace: Bool
    /// Spend only: shown in place of the reset countdown, formatted by the
    /// view in its environment's locale ("$80 of $100").
    public var spend: SpendFigures?

    public init(
        label: String, kind: UsageWindow.Kind, usedPct: Double, fraction: Double,
        percentText: String, level: UsageLevel, paceFraction: Double?, resetsAt: Date?,
        overMarker: Bool, aheadOfPace: Bool, spend: SpendFigures? = nil
    ) {
        self.label = label
        self.kind = kind
        self.usedPct = usedPct
        self.fraction = fraction
        self.percentText = percentText
        self.level = level
        self.paceFraction = paceFraction
        self.resetsAt = resetsAt
        self.overMarker = overMarker
        self.aheadOfPace = aheadOfPace
        self.spend = spend
    }
}

public enum UsageDisplay {
    /// The whole-number percent a person sees. Rounds half to even, like
    /// Python's `f"{pct:.0f}"` in cswap, so the widget and the menu agree.
    public static func displayedPercent(_ pct: Double) -> Int {
        // Clamp as a Double first: converting a huge value to Int traps.
        guard !pct.isNaN, pct > 0 else { return 0 }
        return Int(min(pct, UsageWindow.maxPct).rounded(.toNearestOrEven))
    }

    public static func percentText(_ pct: Double) -> String {
        "\(displayedPercent(pct))%"
    }

    /// Bar fill for a percent: clamped to 0...1, so 130 percent is a full bar.
    public static func fillFraction(_ pct: Double) -> Double {
        clamp01(pct / 100)
    }

    /// Where the pace tick goes, or nil. Only weekly and model windows get a
    /// tick, and only when the source reported `expectedPct`.
    public static func paceFraction(for window: UsageWindow) -> Double? {
        guard window.kind == .weekly || window.kind == .model, window.usedPct != nil,
              let expected = window.expectedPct else { return nil }
        return clamp01(expected / 100)
    }

    /// The window as it stands at `now`. A reset that has passed means the
    /// reported numbers belong to a window that no longer exists: usage reads
    /// 0, the pace tick goes, a weekly window's reset moves forward by whole
    /// periods, and a session window has no reset until it is used again.
    public static func current(_ window: UsageWindow, at now: Date) -> UsageWindow {
        guard let reset = window.resetsAt, reset <= now else { return window }
        var rolled = window
        rolled.usedPct = 0
        rolled.expectedPct = nil
        rolled.aheadOfPace = nil
        if window.kind == .spend { rolled.amount = 0 }
        if window.kind == .session || window.windowSeconds <= 0 {
            rolled.resetsAt = nil
        } else {
            let period = Double(window.windowSeconds)
            let missed = (now.timeIntervalSince(reset) / period).rounded(.down) + 1
            rolled.resetsAt = reset.addingTimeInterval(missed * period)
        }
        return rolled
    }

    /// "$80 of $100", or nil without an amount and a limit.
    public static func spendText(amount: Double?, limit: Double?, currency: String?, locale: Locale = .current) -> String? {
        guard let amount, let limit, amount.isFinite, limit.isFinite else { return nil }
        let code = currency ?? "USD"
        func money(_ value: Double) -> String {
            let whole = value.rounded() == value
            return value.formatted(.currency(code: code).locale(locale).precision(.fractionLength(whole ? 0 : 2)))
        }
        return "\(money(amount)) of \(money(limit))"
    }

    public static func row(for window: UsageWindow, at now: Date) -> WindowRow {
        let current = current(window, at: now)
        var detail: SpendFigures?
        if current.kind == .spend, let amount = current.amount, let limit = current.limit {
            detail = SpendFigures(amount: amount, limit: limit, currency: current.currency ?? "USD")
        }
        guard let pct = current.usedPct else {
            return WindowRow(
                label: current.name, kind: current.kind, usedPct: 0, fraction: 0, percentText: "?",
                level: .unknown, paceFraction: nil, resetsAt: current.resetsAt,
                overMarker: false, aheadOfPace: false, spend: detail
            )
        }
        let level = UsageThresholds.level(for: pct)
        return WindowRow(
            label: current.name,
            kind: current.kind,
            usedPct: pct,
            fraction: fillFraction(pct),
            percentText: percentText(pct),
            level: level,
            paceFraction: paceFraction(for: current),
            resetsAt: current.resetsAt,
            overMarker: level == .over,
            aheadOfPace: (current.aheadOfPace ?? false) && level != .over,
            spend: detail
        )
    }

    static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return value > 0 ? 1 : 0 }
        return min(1, max(0, value))
    }
}
