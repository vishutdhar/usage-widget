import Foundation

/// The App Group both targets share (macOS team-prefixed form).
public enum SharedContainer {
    public static let groupIdentifier = "DABJS94K9F.com.vishutdhar.usagewidget"
    public static let snapshotFileName = "snapshot.json"
    /// One line per reload the agent requests.
    public static let agentLogFileName = "reload-log.txt"
    /// One line per `getTimeline` call the widget receives.
    public static let widgetLogFileName = "timeline-log.txt"
    public static let logCap = 2000

    public static func directory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }
}
