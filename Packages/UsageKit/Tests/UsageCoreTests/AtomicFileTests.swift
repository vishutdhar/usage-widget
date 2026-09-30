import XCTest
@testable import UsageCore

final class AtomicFileTests: XCTestCase {
    func testWritesContentAndLeavesNoTemporaryFiles() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("snapshot.json")
        try AtomicFile.write(Data("hello".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["snapshot.json"])
    }

    /// A rename swaps the directory entry to a new file; an in-place write
    /// would rewrite the old file. A hard link to the old file tells them
    /// apart: after an atomic replace it still holds the old bytes.
    func testReplacesByRenameNotInPlace() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent("snapshot.json")
        let link = dir.appendingPathComponent("old-link.json")
        try Data("old".utf8).write(to: url)
        try FileManager.default.linkItem(at: url, to: link)

        try AtomicFile.write(Data("new".utf8), to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "old")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)),
                       ["snapshot.json", "old-link.json"])
    }

    func testMissingDirectoryThrows() throws {
        let dir = try temporaryDirectory().appendingPathComponent("missing")
        XCTAssertThrowsError(try AtomicFile.write(Data("x".utf8), to: dir.appendingPathComponent("a.json")))
    }
}

final class CappedLogTests: XCTestCase {
    func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    func testAppendsLines() throws {
        let url = try temporaryDirectory().appendingPathComponent("log.txt")
        for i in 1...3 { try CappedLog.append("line \(i)", to: url, cap: 5) }
        XCTAssertEqual(try lines(url), ["line 1", "line 2", "line 3", ""], "each line ends with a newline")
    }

    func testKeepsOnlyTheNewestLines() throws {
        let url = try temporaryDirectory().appendingPathComponent("log.txt")
        for i in 1...7 { try CappedLog.append("line \(i)", to: url, cap: 5) }
        XCTAssertEqual(try lines(url), ["line 3", "line 4", "line 5", "line 6", "line 7", ""])
    }

    func testANewlineInsideALineCannotSplitIt() throws {
        let url = try temporaryDirectory().appendingPathComponent("log.txt")
        try CappedLog.append("a\nb", to: url, cap: 5)
        XCTAssertEqual(try lines(url), ["a b", ""])
    }

    /// One append uses the folder it started with for its lock, read and
    /// write, even when a revalidate runs part way through; the next append
    /// uses the new folder.
    func testOneAppendStaysInTheFolderItStartedIn() throws {
        let parent = try temporaryDirectory()
        let folder = parent.appendingPathComponent("group")
        let moved = parent.appendingPathComponent("group-old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let url = folder.appendingPathComponent("log.txt")
        try CappedLog.append("first", to: url, cap: 5)

        try CappedLog.append("second", to: url, cap: 5, whileLocked: {
            try? FileManager.default.moveItem(at: folder, to: moved)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            XCTAssertEqual(ContainerRoot.revalidate(folder), .replaced)
        })

        XCTAssertEqual(try lines(moved.appendingPathComponent("log.txt")), ["first", "second", ""],
                       "the whole append happened in the folder it locked")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [],
                       "nothing of that append landed in the new folder")

        try CappedLog.append("third", to: url, cap: 5)
        XCTAssertEqual(try lines(url), ["third", ""], "the next append uses the new folder")
    }
}
