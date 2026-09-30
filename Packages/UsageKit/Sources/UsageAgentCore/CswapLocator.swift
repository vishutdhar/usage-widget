import Foundation

/// Finds the cswap binary. A GUI app does not inherit the shell's PATH, so
/// the usual install locations are tried in a fixed order.
public struct CswapLocator: Sendable {
    public var home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// ~/.local/bin (pipx), then Homebrew on Apple silicon, then /usr/local/bin.
    public var candidates: [URL] {
        searchDirectories.map { $0.appendingPathComponent("cswap") }
    }

    /// The directories above, also put in front of the child's PATH.
    public var searchDirectories: [URL] {
        [
            home.appendingPathComponent(".local/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]
    }

    public func resolve(isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) -> URL? {
        candidates.first(where: isExecutable)
    }
}
