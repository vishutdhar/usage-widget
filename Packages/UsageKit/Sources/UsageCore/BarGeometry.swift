import Foundation

/// Bar and tick geometry, the same arithmetic as cswap's menu panel
/// (`fill_width` and `tick_x` in `menubar_panel.py`).
public enum BarGeometry {
    public static let barHeight = 6.0
    public static let tickWidth = 1.5
    /// The tick stands proud of the bar on both sides so it reads over the fill.
    public static let tickOverhang = 2.0

    /// Width of the filled part. Any usage shows at least one round cap.
    public static func fillWidth(barWidth: Double, fraction: Double) -> Double {
        let f = UsageDisplay.clamp01(fraction)
        guard f > 0 else { return 0 }
        return min(barWidth, max(barHeight, f * barWidth))
    }

    /// Left edge of the pace tick: centred on the fraction, kept inside the bar.
    public static func tickX(barWidth: Double, paceFraction: Double) -> Double {
        let left = UsageDisplay.clamp01(paceFraction) * barWidth - tickWidth / 2
        return min(max(left, 0), max(0, barWidth - tickWidth))
    }
}
