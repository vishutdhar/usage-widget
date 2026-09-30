import SwiftUI
import UsageCore

/// Semantic system colours for each usage band, matching the menu bar panel:
/// green below 70, yellow from 70, red from 90.
public extension UsageLevel {
    var fillColor: Color {
        switch self {
        case .ok: return Color(nsColor: .systemGreen)
        case .warn: return Color(nsColor: .systemYellow)
        case .hot, .over: return Color(nsColor: .systemRed)
        case .unknown: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

/// Type and spacing shared by every widget size.
enum Style {
    static let title = Font.system(size: 13)
    static let titleActive = Font.system(size: 13, weight: .semibold)
    static let label = Font.system(size: 11)
    static let digits = Font.system(size: 11).monospacedDigit()
    static let footnote = Font.system(size: 10)
    static let dot = 6.0
    static let rowSpacing = 3.0
    static let columnSpacing = 6.0
    /// The large widget has room to breathe.
    static let largeRowSpacing = 5.0
    static let largeAccountGap = 8.0
    /// Between accounts when the large widget falls back to medium spacing.
    static let denseAccountGap = 6.0
    /// Extra space between the percent and the countdown (the menu uses 10 pt).
    static let resetLeadingGap = 4.0
}
