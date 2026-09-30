import Foundation

public enum WindowLength {
    public static let fiveHours = 5 * 3600
    public static let sevenDays = 7 * 86_400

    /// Short display name for a window length: 18000 -> "5h", 604800 -> "7d".
    public static func shortName(seconds: Int) -> String {
        if seconds >= 86_400, seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds >= 3600, seconds % 3600 == 0 { return "\(seconds / 3600)h" }
        return "\(max(1, seconds / 60))m"
    }
}

extension UsageWindow.Kind {
    /// A window shorter than one day is a session window; a day or longer is weekly.
    public static let sessionLimitSeconds = 86_400

    /// Classifies a window by its length, never by its position in a source's
    /// list (Codex reports its weekly window as "primary" on some plans).
    /// A window scoped to one model is `.model` whatever its length.
    public static func classify(windowSeconds: Int, modelScoped: Bool) -> Self {
        if modelScoped { return .model }
        return windowSeconds < sessionLimitSeconds ? .session : .weekly
    }
}
