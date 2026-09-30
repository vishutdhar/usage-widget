import SwiftUI
import UsageCore

/// One rounded 6 pt bar: a quiet track, a band-coloured fill, and the pace
/// tick where on-schedule usage would be. An unknown value draws no bar; a
/// dimmed one (numbers not current) fills in a secondary colour.
struct UsageBar: View {
    let fraction: Double
    let level: UsageLevel
    let paceFraction: Double?
    var dimmed = false

    var body: some View {
        if level == .unknown {
            Color.clear.frame(height: BarGeometry.barHeight + 2 * BarGeometry.tickOverhang)
        } else {
            bar
        }
    }

    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fill = BarGeometry.fillWidth(barWidth: width, fraction: fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                if fill > 0 {
                    Capsule().fill(dimmed ? Color(nsColor: .secondaryLabelColor) : level.fillColor).frame(width: fill)
                }
                if let paceFraction {
                    RoundedRectangle(cornerRadius: BarGeometry.tickWidth / 2)
                        .fill(Color.primary)
                        .frame(width: BarGeometry.tickWidth,
                               height: BarGeometry.barHeight + 2 * BarGeometry.tickOverhang)
                        .offset(x: BarGeometry.tickX(barWidth: width, paceFraction: paceFraction))
                }
            }
            .frame(height: BarGeometry.barHeight)
            .frame(maxHeight: .infinity)
        }
        .frame(height: BarGeometry.barHeight + 2 * BarGeometry.tickOverhang)
        .accessibilityHidden(true)
    }
}
