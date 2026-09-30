import XCTest
import UsageCore
@testable import UsageAgentCore

final class CodexPathsTests: XCTestCase {
    func testBinaryOrderAndPath() {
        let paths = CodexPaths(home: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(paths.binaryCandidates.map(\.path),
                       ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Users/someone/.local/bin/codex"])
        XCTAssertEqual(paths.resolveBinary { $0.path.hasPrefix("/usr") }?.path, "/usr/local/bin/codex")
        XCTAssertNil(paths.resolveBinary { _ in false })
        XCTAssertEqual(paths.searchDirectories.first?.path, "/opt/homebrew/bin", "node lives in Homebrew")
        XCTAssertEqual(paths.sessions.path, "/Users/someone/.codex/sessions")
    }
}

/// A home with ~/.codex/sessions and a sentinel standing in for auth.json:
/// a recognisable rate limits line, so reading it would show 77%.
struct CodexHomeFixture {
    let home: URL
    var paths: CodexPaths { CodexPaths(home: home, systemDirectories: []) }
    var codexHome: URL { paths.codexHome }
    var sessions: URL { paths.sessions }
    var auth: URL { codexHome.appendingPathComponent("auth.json") }
    static let sentinelLine = #"{"timestamp":"2026-09-27T13:59:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":77,"window_minutes":10080,"resets_at":1791072000},"secondary":null,"plan_type":"pro"}}}"#

    init() throws {
        home = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: paths.sessions, withIntermediateDirectories: true)
        try Data((Self.sentinelLine + "\n").utf8).write(to: auth)
    }

    func dayDirectory(_ date: Date, calendar: Calendar) throws -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

func rateLimitLine(pct: Double, at stamp: String, plan: String = "pro") -> String {
    #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(pct),"window_minutes":10080,"resets_at":1791072000},"secondary":null,"plan_type":"\#(plan)","limit_id":"codex"}}}"#
}

func inode(_ url: URL) -> UInt64 {
    var st = stat()
    lstat(url.path, &st)
    return UInt64(st.st_ino)
}

/// Opens through the real no-follow opener and records the inode of every
/// descriptor it hands back, so a test can prove a file was never opened.
final class RecordingOpener: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var openedInodes: [UInt64] = []
    /// Runs just before the open: a swap here lands between the reader's
    /// checks and its open.
    var beforeOpen: () -> Void = {}
    /// The folder descriptors opened through, in order.
    private(set) var folderInodes: [UInt64] = []

    func open(_ dirfd: Int32, _ name: String) -> Int32 {
        beforeOpen()
        var folder = stat()
        fstat(dirfd, &folder)
        lock.withLock { folderInodes.append(UInt64(folder.st_ino)) }
        let fd = SafeFile.openAtNoFollow(dirfd, name)
        lock.withLock {
            calls += 1
            if fd >= 0 {
                var st = stat()
                fstat(fd, &st)
                openedInodes.append(UInt64(st.st_ino))
            }
        }
        return fd
    }
}

final class RolloutFinderTests: XCTestCase {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    let now = ISODate.parse("2026-09-27T14:00:00Z")!

    @discardableResult
    func file(in sessions: URL, daysAgo: Int, name: String, modified: Date, text: String = "{}\n") throws -> URL {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func names(_ sessions: URL) -> [String] {
        RolloutFinder.newest(in: sessions, now: now, calendar: calendar).map { URL(fileURLWithPath: $0.path).lastPathComponent }
    }

    /// Codex names its day folders by the Gregorian calendar. A Mac set to
    /// another calendar (Buddhist here, year 2569) still finds them.
    func testDayFoldersAreGregorianWhateverTheCalendar() throws {
        let sessions = try makeTemporaryDirectory().appendingPathComponent("sessions")
        try file(in: sessions, daysAgo: 0, name: "rollout-today.jsonl", modified: now)
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        XCTAssertEqual(RolloutFinder.newest(in: sessions, now: now, calendar: buddhist)
                        .map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["rollout-today.jsonl"])
    }

    func testNoSessionsGivesNothing() throws {
        let sessions = try makeTemporaryDirectory().appendingPathComponent("sessions")
        XCTAssertEqual(names(sessions), [], "missing directory")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        XCTAssertEqual(names(sessions), [], "empty directory")
    }

    func testTheNewestFilesByModificationTimeComeFirst() throws {
        let sessions = try makeTemporaryDirectory()
        try file(in: sessions, daysAgo: 0, name: "rollout-a.jsonl", modified: now.addingTimeInterval(-3600))
        try file(in: sessions, daysAgo: 1, name: "rollout-b.jsonl", modified: now.addingTimeInterval(-60))
        try file(in: sessions, daysAgo: 0, name: "notes.txt", modified: now)
        try file(in: sessions, daysAgo: 0, name: "history.jsonl", modified: now)
        try file(in: sessions, daysAgo: 0, name: "rollout-partial.json", modified: now)
        XCTAssertEqual(names(sessions), ["rollout-b.jsonl", "rollout-a.jsonl"])
    }

    /// A long session keeps writing to the file in the directory of the day
    /// it started, so every one of the seven day directories is looked at.
    func testALongRunningSessionFromDaysAgoStillCounts() throws {
        let sessions = try makeTemporaryDirectory()
        try file(in: sessions, daysAgo: 0, name: "rollout-today.jsonl", modified: now.addingTimeInterval(-7200))
        try file(in: sessions, daysAgo: 4, name: "rollout-long.jsonl", modified: now.addingTimeInterval(-30))
        XCTAssertEqual(names(sessions).first, "rollout-long.jsonl")
    }

    func testTheScanIsBoundedToSevenDays() throws {
        let sessions = try makeTemporaryDirectory()
        try file(in: sessions, daysAgo: 9, name: "rollout-old.jsonl", modified: now)
        XCTAssertEqual(names(sessions), [])
        try file(in: sessions, daysAgo: 6, name: "rollout-edge.jsonl", modified: now.addingTimeInterval(-600))
        XCTAssertEqual(names(sessions), ["rollout-edge.jsonl"])
    }

    func testAtMostFiveFilesAreReturned() throws {
        let sessions = try makeTemporaryDirectory()
        for i in 0..<7 {
            try file(in: sessions, daysAgo: 0, name: "rollout-\(i).jsonl", modified: now.addingTimeInterval(Double(-60 * i)))
        }
        XCTAssertEqual(names(sessions), (0..<5).map { "rollout-\($0).jsonl" })
    }

    /// Only regular files count: a symlink, a directory, a FIFO or a second
    /// name for another file (a hard link) is skipped, whatever it is called.
    func testOnlyRegularSingleLinkFilesAreFound() throws {
        let fixture = try CodexHomeFixture()
        let day = try fixture.dayDirectory(now, calendar: calendar)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: day.appendingPathComponent("rollout-link.jsonl"), withDestinationURL: fixture.auth)
        try fm.createDirectory(at: day.appendingPathComponent("rollout-dir.jsonl"), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(day.appendingPathComponent("rollout-fifo.jsonl").path, 0o600), 0)
        XCTAssertEqual(link(fixture.auth.path, day.appendingPathComponent("rollout-hard.jsonl").path), 0)
        try Data("{}\n".utf8).write(to: day.appendingPathComponent("rollout-real.jsonl"))
        XCTAssertEqual(RolloutFinder.newest(in: fixture.sessions, now: now, calendar: calendar)
                        .map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["rollout-real.jsonl"])
    }

    /// A day folder that is a link to somewhere outside the sessions folder
    /// is not followed.
    func testADayFolderLeadingOutsideTheSessionsFolderIsIgnored() throws {
        let fixture = try CodexHomeFixture()
        let outside = try makeTemporaryDirectory()
        try Data("{}\n".utf8).write(to: outside.appendingPathComponent("rollout-outside.jsonl"))
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let month = fixture.sessions.appendingPathComponent(String(format: "%04d/%02d", parts.year!, parts.month!))
        try FileManager.default.createDirectory(at: month, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: month.appendingPathComponent(String(format: "%02d", parts.day!)),
                                                   withDestinationURL: outside)
        XCTAssertEqual(RolloutFinder.newest(in: fixture.sessions, now: now, calendar: calendar).count, 0)
    }
}

final class RolloutReaderTests: XCTestCase {
    func discovered(_ url: URL) throws -> RolloutFile {
        try XCTUnwrap(RolloutFile.regular(at: url.path))
    }

    func sessionFile(_ fixture: CodexHomeFixture, _ name: String, _ text: String) throws -> URL {
        let url = try fixture.dayDirectory(Date(), calendar: .current).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testASmallFileIsReadWhole() throws {
        let fixture = try CodexHomeFixture()
        let url = try sessionFile(fixture, "rollout-x.jsonl", "one\ntwo\n")
        XCTAssertEqual(RolloutReader.tail(of: try discovered(url), paths: fixture.paths)
                        .map { String(decoding: $0, as: UTF8.self) }, "one\ntwo\n")
    }

    func testALargeFileGivesItsTailFromALineBoundary() throws {
        let fixture = try CodexHomeFixture()
        var text = ""
        for i in 0..<20_000 { text += "line \(i) " + String(repeating: "x", count: 30) + "\n" }
        let url = try sessionFile(fixture, "rollout-x.jsonl", text)
        let tail = try XCTUnwrap(RolloutReader.tail(of: try discovered(url), paths: fixture.paths, maxBytes: 64 * 1024))
        XCTAssertLessThanOrEqual(tail.count, 64 * 1024)
        let string = String(decoding: tail, as: UTF8.self)
        XCTAssertTrue(string.hasPrefix("line "), "no partial first line")
        XCTAssertTrue(string.hasSuffix("line 19999 " + String(repeating: "x", count: 30) + "\n"))
    }

    func testAMissingFileGivesNothing() throws {
        let fixture = try CodexHomeFixture()
        let url = try sessionFile(fixture, "rollout-x.jsonl", "{}\n")
        let file = try discovered(url)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(RolloutReader.tail(of: file, paths: fixture.paths))
    }

    /// A writer appending while the tail is read cannot push the read past
    /// the cap: the size is taken once, at open.
    func testAnAppendDuringTheReadIsNotRead() throws {
        let fixture = try CodexHomeFixture()
        let original = String(repeating: "a line of the session\n", count: 20)
        let url = try sessionFile(fixture, "rollout-x.jsonl", original)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let tail = RolloutReader.tail(of: try discovered(url), paths: fixture.paths, maxBytes: 1024, beforeRead: {
            handle.seekToEndOfFile()
            handle.write(Data(String(repeating: "appended during the read\n", count: 40_000).utf8))
        })
        XCTAssertEqual(tail.map { String(decoding: $0, as: UTF8.self) }, original)
    }
}

/// Nothing but a regular, single-link file inside ~/.codex/sessions is ever
/// opened, and auth.json never is, whatever path the reader is handed.
final class CodexFileSafetyTests: XCTestCase {
    func handMade(_ path: URL, like target: URL) throws -> RolloutFile {
        var st = stat()
        XCTAssertEqual(lstat(target.path, &st), 0)
        return RolloutFile(path: path.path, modified: Date(), device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
    }

    func testAuthJsonIsNeverOpenedEvenWithoutDiscovery() throws {
        let fixture = try CodexHomeFixture()
        let opener = RecordingOpener()
        XCTAssertNil(RolloutReader.tail(of: try handMade(fixture.auth, like: fixture.auth), paths: fixture.paths,
                                        opener: opener.open))
        // Even a copy named auth.json inside the sessions folder is refused.
        let day = try fixture.dayDirectory(Date(), calendar: .current)
        let named = day.appendingPathComponent("auth.json")
        try Data((CodexHomeFixture.sentinelLine + "\n").utf8).write(to: named)
        XCTAssertNil(RolloutReader.tail(of: try handMade(named, like: named), paths: fixture.paths, opener: opener.open))
        XCTAssertEqual(opener.calls, 0, "refused before any open")
    }

    func testFilesOutsideTheSessionsFolderAreNeverOpened() throws {
        let fixture = try CodexHomeFixture()
        let opener = RecordingOpener()
        let direct = fixture.codexHome.appendingPathComponent("rollout-x.jsonl")
        try Data((CodexHomeFixture.sentinelLine + "\n").utf8).write(to: direct)
        XCTAssertNil(RolloutReader.tail(of: try handMade(direct, like: direct), paths: fixture.paths, opener: opener.open))
        let elsewhere = try makeTemporaryDirectory().appendingPathComponent("rollout-y.jsonl")
        try Data((CodexHomeFixture.sentinelLine + "\n").utf8).write(to: elsewhere)
        XCTAssertNil(RolloutReader.tail(of: try handMade(elsewhere, like: elsewhere), paths: fixture.paths, opener: opener.open))
        XCTAssertEqual(opener.calls, 0)
    }

    /// A rollout name that is a symlink to the sentinel: handed the
    /// sentinel's own identity, the reader still never opens the sentinel.
    func testASymlinkIsNeverFollowed() throws {
        let fixture = try CodexHomeFixture()
        let day = try fixture.dayDirectory(Date(), calendar: .current)
        let link = day.appendingPathComponent("rollout-link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.auth)
        let opener = RecordingOpener()
        XCTAssertNil(RolloutReader.tail(of: try handMade(link, like: fixture.auth), paths: fixture.paths, opener: opener.open))
        XCTAssertFalse(opener.openedInodes.contains(inode(fixture.auth)), "the sentinel was opened")
        let collector = CodexCollector(paths: fixture.paths)
        XCTAssertNil(collector.rolloutReading(now: Date()), "nothing readable, and never the sentinel's 77%")
    }

    /// The file found at discovery is swapped for another before it is read.
    func testASwappedFileIsRejected() throws {
        let fixture = try CodexHomeFixture()
        let day = try fixture.dayDirectory(Date(), calendar: .current)
        let url = day.appendingPathComponent("rollout-x.jsonl")
        try Data((rateLimitLine(pct: 10, at: "2026-09-27T13:00:00.000Z") + "\n").utf8).write(to: url)
        let found = try XCTUnwrap(RolloutFile.regular(at: url.path))
        let other = day.appendingPathComponent("rollout-y.tmp")
        try Data((CodexHomeFixture.sentinelLine + "\n").utf8).write(to: other)
        XCTAssertEqual(rename(other.path, url.path), 0)
        let early = RecordingOpener()
        XCTAssertNil(RolloutReader.tail(of: found, paths: fixture.paths, opener: early.open), "another file now sits at that path")
        XCTAssertEqual(early.calls, 0, "refused before the open")

        // And swapped for a symlink to the sentinel.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: fixture.auth)
        let opener = RecordingOpener()
        XCTAssertNil(RolloutReader.tail(of: found, paths: fixture.paths, opener: opener.open))
        XCTAssertFalse(opener.openedInodes.contains(inode(fixture.auth)))
    }

    /// The swap lands after every check and just before the open: the
    /// no-follow open refuses a symlink, and the identity check after the
    /// open refuses any other file, so neither is ever read.
    func testASwapBetweenTheChecksAndTheOpenIsCaught() throws {
        let fixture = try CodexHomeFixture()
        let day = try fixture.dayDirectory(Date(), calendar: .current)
        let url = day.appendingPathComponent("rollout-x.jsonl")
        try Data((rateLimitLine(pct: 10, at: "2026-09-27T13:00:00.000Z") + "\n").utf8).write(to: url)
        let found = try XCTUnwrap(RolloutFile.regular(at: url.path))

        let toLink = RecordingOpener()
        toLink.beforeOpen = {
            unlink(url.path)
            symlink(fixture.auth.path, url.path)
        }
        XCTAssertNil(RolloutReader.tail(of: found, paths: fixture.paths, opener: toLink.open))
        XCTAssertFalse(toLink.openedInodes.contains(inode(fixture.auth)), "the sentinel was opened through the link")

        unlink(url.path)
        try Data((rateLimitLine(pct: 10, at: "2026-09-27T13:00:00.000Z") + "\n").utf8).write(to: url)
        let refound = try XCTUnwrap(RolloutFile.regular(at: url.path))
        let toFile = RecordingOpener()
        toFile.beforeOpen = {
            let other = url.path + ".swap"
            try? Data((CodexHomeFixture.sentinelLine + "\n").utf8).write(to: URL(fileURLWithPath: other))
            rename(other, url.path)
        }
        XCTAssertNil(RolloutReader.tail(of: refound, paths: fixture.paths, opener: toFile.open), "a different file is not read")
    }

    /// Only sessions/YYYY/MM/DD/name is ever opened: a rollout name at any
    /// other depth under the sessions folder is refused.
    func testOnlyDayFoldersAreRead() throws {
        let fixture = try CodexHomeFixture()
        let year = fixture.sessions.appendingPathComponent("2026")
        try FileManager.default.createDirectory(at: year.appendingPathComponent("09"), withIntermediateDirectories: true)
        let opener = RecordingOpener()
        for url in [fixture.sessions.appendingPathComponent("rollout-a.jsonl"), year.appendingPathComponent("rollout-b.jsonl"),
                    year.appendingPathComponent("09/rollout-c.jsonl")] {
            try Data((rateLimitLine(pct: 10, at: "2026-09-27T13:00:00.000Z") + "\n").utf8).write(to: url)
            XCTAssertNil(RolloutReader.tail(of: try handMade(url, like: url), paths: fixture.paths, opener: opener.open),
                         url.lastPathComponent)
        }
        XCTAssertEqual(opener.calls, 0)
    }

    /// The day folder found at discovery is held open: a swap of an ancestor
    /// folder afterwards, with a decoy rollout of the same name, cannot
    /// redirect the open. It reaches the file discovery found, through the
    /// same folder, and never the decoy.
    func testAnAncestorSwapAfterDiscoveryCannotReachADecoy() throws {
        let fixture = try CodexHomeFixture()
        let now = Date()
        let day = try fixture.dayDirectory(now, calendar: .current)
        try Data((rateLimitLine(pct: 70, at: "2026-09-27T13:00:00.000Z") + "\n").utf8)
            .write(to: day.appendingPathComponent("rollout-x.jsonl"))
        let found = try XCTUnwrap(RolloutFinder.newest(in: fixture.sessions, now: now).first)
        var dayStat = stat()
        XCTAssertEqual(lstat(day.path, &dayStat), 0)

        // Replace the whole year folder with a decoy tree.
        let year = day.deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(rename(year.path, year.path + ".moved"), 0)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let decoy = day.appendingPathComponent("rollout-x.jsonl")
        try Data((CodexHomeFixture.sentinelLine + "\n").utf8).write(to: decoy)

        let opener = RecordingOpener()
        let tail = try XCTUnwrap(RolloutReader.tail(of: found, paths: fixture.paths, opener: opener.open))
        XCTAssertTrue(String(decoding: tail, as: UTF8.self).contains("\"used_percent\":70"), "the file discovery found")
        XCTAssertFalse(opener.openedInodes.contains(inode(decoy)), "the decoy was opened")
        XCTAssertEqual(opener.folderInodes, [UInt64(dayStat.st_ino)], "opened through the day folder found at discovery")
    }

    /// Even when the sessions folder is itself a link to ~/.codex, nothing
    /// directly in ~/.codex is opened.
    func testASessionsFolderLinkedToCodexHomeStillRefusesItsFiles() throws {
        let home = try makeTemporaryDirectory()
        let paths = CodexPaths(home: home, systemDirectories: [])
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.sessions, withDestinationURL: paths.codexHome)
        let direct = paths.codexHome.appendingPathComponent("rollout-x.jsonl")
        try Data((CodexHomeFixture.sentinelLine + "\n").utf8).write(to: direct)
        let opener = RecordingOpener()
        XCTAssertNil(RolloutReader.tail(of: try handMade(direct, like: direct), paths: paths, opener: opener.open))
        XCTAssertEqual(opener.calls, 0)
    }

    /// A hard link carries the sentinel's own identity, so only its link
    /// count gives it away; it is refused before any open.
    func testAHardLinkIsRejected() throws {
        let fixture = try CodexHomeFixture()
        let day = try fixture.dayDirectory(Date(), calendar: .current)
        let hard = day.appendingPathComponent("rollout-hard.jsonl")
        XCTAssertEqual(link(fixture.auth.path, hard.path), 0)
        let opener = RecordingOpener()
        XCTAssertNil(RolloutReader.tail(of: try handMade(hard, like: hard), paths: fixture.paths, opener: opener.open))
        XCTAssertEqual(opener.calls, 0)
    }

    func testADirectoryOrFIFONamedLikeARolloutIsRejected() throws {
        let fixture = try CodexHomeFixture()
        let day = try fixture.dayDirectory(Date(), calendar: .current)
        let dir = day.appendingPathComponent("rollout-dir.jsonl")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fifo = day.appendingPathComponent("rollout-fifo.jsonl")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let opener = RecordingOpener()
        XCTAssertNil(RolloutReader.tail(of: try handMade(dir, like: dir), paths: fixture.paths, opener: opener.open))
        XCTAssertNil(RolloutReader.tail(of: try handMade(fifo, like: fifo), paths: fixture.paths, opener: opener.open))
        XCTAssertEqual(opener.calls, 0)
    }
}

/// Which rollout reading the collector reports.
final class CodexCollectorTests: XCTestCase {
    let now = ISODate.parse("2026-09-27T15:00:00Z")!

    func write(_ fixture: CodexHomeFixture, _ name: String, lines: [String], modified: Date) throws {
        let url = try fixture.dayDirectory(now, calendar: .current).appendingPathComponent(name)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func at(_ time: String) -> Date { ISODate.parse("2026-09-27T\(time):00Z")! }

    /// Session B was touched last but its newest limits are older.
    func testTheNewestEventWinsNotTheNewestFile() throws {
        let fixture = try CodexHomeFixture()
        try write(fixture, "rollout-a.jsonl", lines: [rateLimitLine(pct: 90, at: "2026-09-27T14:00:00.000Z")],
                  modified: at("14:05"))
        try write(fixture, "rollout-b.jsonl", lines: [rateLimitLine(pct: 20, at: "2026-09-27T12:00:00.000Z"),
                                                     #"{"timestamp":"2026-09-27T14:29:00.000Z","type":"response_item","payload":{}}"#],
                  modified: at("14:30"))
        let reading = try XCTUnwrap(CodexCollector(paths: fixture.paths).rolloutReading(now: now))
        XCTAssertEqual(reading.windows.map(\.usedPct), [90])
        XCTAssertEqual(reading.measuredAt, at("14:00"))
    }

    func testAFileWithoutLimitsDoesNotHideAnOlderOne() throws {
        let fixture = try CodexHomeFixture()
        try write(fixture, "rollout-new.jsonl", lines: [#"{"timestamp":"2026-09-27T14:50:00.000Z","type":"session_meta","payload":{}}"#],
                  modified: at("14:50"))
        try write(fixture, "rollout-old.jsonl", lines: [rateLimitLine(pct: 55, at: "2026-09-27T13:00:00.000Z")],
                  modified: at("13:00"))
        XCTAssertEqual(try XCTUnwrap(CodexCollector(paths: fixture.paths).rolloutReading(now: now)).windows.map(\.usedPct), [55])
    }

    func testOnlyTheFiveNewestFilesAreRead() throws {
        let fixture = try CodexHomeFixture()
        for i in 0..<5 {
            try write(fixture, "rollout-\(i).jsonl", lines: [rateLimitLine(pct: 30, at: "2026-09-27T13:0\(i):00.000Z")],
                      modified: at("14:4\(i)"))
        }
        // The sixth newest by modification time holds the newest event; it is not read.
        try write(fixture, "rollout-6.jsonl", lines: [rateLimitLine(pct: 95, at: "2026-09-27T14:30:00.000Z")],
                  modified: at("14:31"))
        XCTAssertEqual(try XCTUnwrap(CodexCollector(paths: fixture.paths).rolloutReading(now: now)).windows.map(\.usedPct), [30])
    }

    /// A file whose events all claim the future adds nothing; the other
    /// file's reading is used.
    func testAnAllFutureFileContributesNothing() throws {
        let fixture = try CodexHomeFixture()
        try write(fixture, "rollout-a.jsonl", lines: [rateLimitLine(pct: 80, at: "2026-09-27T18:00:00.000Z")],
                  modified: at("14:59"))
        try write(fixture, "rollout-b.jsonl", lines: [rateLimitLine(pct: 30, at: "2026-09-27T12:00:00.000Z")],
                  modified: at("12:00"))
        let reading = try XCTUnwrap(CodexCollector(paths: fixture.paths).rolloutReading(now: now))
        XCTAssertEqual(reading.windows.map(\.usedPct), [30])
    }

    func testAFutureLastEventLeavesTheFilesEarlierOne() throws {
        let fixture = try CodexHomeFixture()
        try write(fixture, "rollout-a.jsonl", lines: [rateLimitLine(pct: 70, at: "2026-09-27T13:00:00.000Z"),
                                                     rateLimitLine(pct: 80, at: "2026-09-27T18:00:00.000Z")],
                  modified: at("14:59"))
        let reading = try XCTUnwrap(CodexCollector(paths: fixture.paths).rolloutReading(now: now))
        XCTAssertEqual(reading.windows.map(\.usedPct), [70])
        XCTAssertEqual(reading.measuredAt, at("13:00"))
    }

    /// The clock set back hours and forward again: the reading is skipped
    /// while it looks ahead, and is its own time otherwise; never re-dated.
    func testASetBackClockNeverRedatesAReading() throws {
        let fixture = try CodexHomeFixture()
        let collector = CodexCollector(paths: fixture.paths)
        try write(fixture, "rollout-a.jsonl", lines: [rateLimitLine(pct: 80, at: "2026-09-27T18:00:00.000Z")],
                  modified: at("18:00"))
        XCTAssertEqual(collector.rolloutReading(now: at("18:05"))?.measuredAt, at("18:00"))
        XCTAssertNil(collector.rolloutReading(now: at("10:00")))
        XCTAssertEqual(collector.rolloutReading(now: at("18:06"))?.measuredAt, at("18:00"))
    }

    func testAnEventLessThanTwoMinutesAheadIsKept() throws {
        let fixture = try CodexHomeFixture()
        try write(fixture, "rollout-a.jsonl", lines: [rateLimitLine(pct: 80, at: "2026-09-27T15:01:30.000Z")],
                  modified: at("15:00"))
        let reading = try XCTUnwrap(CodexCollector(paths: fixture.paths).rolloutReading(now: now))
        XCTAssertEqual(reading.measuredAt, ISODate.parse("2026-09-27T15:01:30Z"))
    }
}

final class CodexCollectorClientTests: XCTestCase {
    /// A collector for another home looks for codex only under that home.
    func testTheClientSharesTheCollectorsPaths() throws {
        let home = try makeTemporaryDirectory()
        let collector = CodexCollector(paths: CodexPaths(home: home, systemDirectories: []))
        XCTAssertEqual(collector.client.paths.home, home)
        XCTAssertEqual(collector.client.paths.systemDirectories, [])
        XCTAssertNil(collector.client.paths.resolveBinary())
    }
}
