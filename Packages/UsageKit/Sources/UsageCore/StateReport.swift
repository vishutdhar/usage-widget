import Foundation

/// The text `--print-state` prints: each container file whole, and the
/// tails of both logs. Every file is read through SafeFile, so a link or
/// any other odd file is reported as refused and never read.
public enum StateReport {
    /// - Parameter extraFiles: more files printed whole (the agent's own).
    public static func text(in directory: URL, lines: Int, extraFiles: [String] = []) -> String {
        var out = "container: \(directory.path)\n"
        let whole = [SharedContainer.snapshotFileName, ReloadStateStore.fileName, WriterStateStore.fileName]
            + extraFiles + [RefreshRequestStore.fileName]
        let entries = whole.map { ($0, nil as Int?) }
            + [(SharedContainer.agentLogFileName, lines as Int?), (SharedContainer.widgetLogFileName, lines as Int?)]
        for (name, tail) in entries {
            out += "\n--- \(name)\n"
            let text: String
            switch SafeFile.read(directory.appendingPathComponent(name)) {
            case .missing:
                out += "(missing)\n"
                continue
            case .refused(let reason):
                out += "(refused: \(reason))\n"
                continue
            case .data(let data):
                text = String(decoding: data, as: UTF8.self)
            }
            if let tail {
                let all = text.split(separator: "\n")
                out += "(\(all.count) lines, last \(min(tail, all.count)))\n"
                out += all.suffix(tail).joined(separator: "\n") + "\n"
            } else {
                out += text.hasSuffix("\n") ? text : text + "\n"
            }
        }
        return out
    }
}
