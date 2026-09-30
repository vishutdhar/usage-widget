import Foundation
import UsageAgentCore
import UsageCore

/// `Usage Widget --print-state [lines]` prints the snapshot, the reload
/// state, the Codex call log and the tails of both refresh logs, then exits
/// without starting the agent.
///
/// macOS keeps other processes (a terminal without Full Disk Access, for
/// example) out of an app's group container, so this is how a person reads
/// the measurement logs: the binary carries the group entitlement itself.
enum StateDump {
    static let flag = "--print-state"
    /// Writes a refresh request exactly as the widget's button does, then
    /// exits: a way to press the button from a terminal.
    static let refreshFlag = "--request-refresh"

    static func requestRefresh() -> Int32 {
        guard let directory = SharedContainer.directory() else {
            FileHandle.standardError.write(Data("The shared container is unavailable.\n".utf8))
            return 1
        }
        do {
            try RefreshRequestStore.request(in: directory, at: Date())
            FileHandle.standardOutput.write(Data("refresh requested at \(ISODate.format(Date()))\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("Could not write the request: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Nil when the flag is absent; otherwise how many log lines to print.
    static func requestedLines(from arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        if next < arguments.endIndex, let lines = Int(arguments[next]), lines > 0 { return lines }
        return 20
    }

    static func run(lines: Int) -> Int32 {
        guard let directory = SharedContainer.directory() else {
            FileHandle.standardError.write(Data("The shared container is unavailable.\n".utf8))
            return 1
        }
        let out = StateReport.text(in: directory, lines: lines, extraFiles: [CodexCallLogStore.fileName])
        FileHandle.standardOutput.write(Data(out.utf8))
        return 0
    }
}
