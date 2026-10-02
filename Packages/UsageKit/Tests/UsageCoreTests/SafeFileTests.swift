import XCTest
@testable import UsageCore

/// Every file in the shared container is read and written through SafeFile:
/// regular single-link files only, never through a link.
final class SafeFileTests: XCTestCase {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("safefile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file outside the container with contents every reader would accept.
    func sentinel(_ contents: String) throws -> URL {
        let url = try tempDir().appendingPathComponent("secret")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testARegularFileIsReadAndAMissingOneIsMissing() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("a.json")
        XCTAssertEqual(SafeFile.read(url), .missing)
        try SafeFile.write(Data("hello".utf8), to: url)
        XCTAssertEqual(SafeFile.read(url), .data(Data("hello".utf8)))
    }

    func testLinksFifosAndFoldersAreRefusedWithoutOpeningTheTarget() throws {
        let dir = try tempDir()
        let secret = try sentinel("SENTINEL")
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let hard = dir.appendingPathComponent("hard.json")
        XCTAssertEqual(Darwin.link(secret.path, hard.path), 0)
        let fifo = dir.appendingPathComponent("fifo.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let folder = dir.appendingPathComponent("folder.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var opened = 0
        for url in [link, hard, fifo, folder] {
            let result = SafeFile.read(url, open: { opened += 1; return SafeFile.openAtNoFollow($0, $1) })
            guard case .refused = result else { return XCTFail("\(url.lastPathComponent): \(result)") }
        }
        XCTAssertEqual(opened, 0, "refused on lstat, before any open")
    }

    /// A swap landing after lstat and just before the open: the no-follow
    /// open refuses a link (the sentinel is never opened), and the identity
    /// check after the open refuses any other file.
    func testASwapBetweenTheChecksAndTheOpenIsCaught() throws {
        let dir = try tempDir()
        let secret = try sentinel("SENTINEL")
        var sentinelStat = stat()
        XCTAssertEqual(lstat(secret.path, &sentinelStat), 0)
        let url = dir.appendingPathComponent("snapshot.json")
        try SafeFile.write(Data("mine".utf8), to: url)
        var openedInodes: [ino_t] = []
        let toLink = SafeFile.read(url, open: { dirfd, name in
            unlink(url.path)
            symlink(secret.path, url.path)
            let fd = SafeFile.openAtNoFollow(dirfd, name)
            var st = stat()
            if fd >= 0, fstat(fd, &st) == 0 { openedInodes.append(st.st_ino) }
            return fd
        })
        guard case .refused = toLink else { return XCTFail("read through a swapped-in link: \(toLink)") }
        XCTAssertFalse(openedInodes.contains(sentinelStat.st_ino), "the sentinel was opened")

        unlink(url.path)
        try SafeFile.write(Data("mine".utf8), to: url)
        let toFile = SafeFile.read(url, open: { dirfd, name in
            let other = url.path + ".swap"
            try? Data("SENTINEL".utf8).write(to: URL(fileURLWithPath: other))
            rename(other, url.path)
            return SafeFile.openAtNoFollow(dirfd, name)
        })
        guard case .refused = toFile else { return XCTFail("read a swapped-in file: \(toFile)") }
    }

    /// The agent's atomic rename can land between the lstat and the open:
    /// the file opened is the new, legitimate one. The read looks again
    /// (up to three times) and reads it; only a swap on every look is
    /// refused.
    func testAReplacementBetweenTheChecksIsReadOnALaterLook() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("snapshot.json")
        func replace(_ text: String) {
            let other = url.path + ".new"
            try? Data(text.utf8).write(to: URL(fileURLWithPath: other))
            rename(other, url.path)
        }
        for swaps in [1, 2] {
            replace("old")
            var opened = 0
            let result = SafeFile.read(url, open: { dirfd, name in
                opened += 1
                if opened <= swaps { replace("new \(opened)") }
                return SafeFile.openAtNoFollow(dirfd, name)
            })
            XCTAssertEqual(result, .data(Data("new \(swaps)".utf8)), "replaced \(swaps) times, then stable")
            XCTAssertEqual(opened, swaps + 1)
        }
        replace("old")
        var opened = 0
        let result = SafeFile.read(url, open: { dirfd, name in
            opened += 1
            replace("new \(opened)")
            return SafeFile.openAtNoFollow(dirfd, name)
        })
        guard case .refused = result else { return XCTFail("a swap on every look was read: \(result)") }
        XCTAssertEqual(opened, 3, "three looks, then refused")
    }

    /// The folder is anchored as a directory descriptor: a folder that is a
    /// link is refused when anchored, and nothing is read or written there.
    func testALinkedFolderIsRefusedWhenAnchored() throws {
        let real = try tempDir()
        let link = try tempDir().appendingPathComponent("container")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        guard case .refused = ContainerRoot.anchor(link) else { return XCTFail("a linked folder was anchored") }
        XCTAssertThrowsError(try SafeFile.write(Data("x".utf8), to: link.appendingPathComponent("a.json")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: real.appendingPathComponent("a.json").path))
        guard case .refused = SafeFile.read(link.appendingPathComponent("a.json")) else { return XCTFail("read") }
    }

    /// Once anchored, the folder is its inode: swapping another folder in
    /// at the same path afterwards cannot redirect a write.
    func testASwapOfTheFolderAfterAnchoringCannotRedirectAWrite() throws {
        let parent = try tempDir()
        let folder = parent.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SafeFile.write(Data("one".utf8), to: folder.appendingPathComponent("a.json"))
        let moved = parent.appendingPathComponent("moved")
        XCTAssertEqual(rename(folder.path, moved.path), 0)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SafeFile.write(Data("two".utf8), to: folder.appendingPathComponent("a.json"))
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("a.json"), encoding: .utf8), "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.json").path))
    }

    /// A container replaced at its path is picked up when the anchor is
    /// checked again: the next write lands in the new folder.
    func testARecreatedFolderIsReanchoredOnTheNextCheck() throws {
        let parent = try tempDir()
        let folder = parent.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SafeFile.write(Data("one".utf8), to: folder.appendingPathComponent("a.json"))
        XCTAssertEqual(ContainerRoot.revalidate(folder), .unchanged)
        XCTAssertEqual(rename(folder.path, parent.appendingPathComponent("old").path), 0)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(ContainerRoot.revalidate(folder), .replaced)
        try SafeFile.write(Data("two".utf8), to: folder.appendingPathComponent("a.json"))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.json"), encoding: .utf8), "two")
        XCTAssertEqual(ContainerRoot.revalidate(folder), .unchanged)
    }

    /// The identity is compared before the successor is
    /// opened. A replacement that cannot be opened (mode 000) is still a
    /// replacement, not a refusal; the old anchor stays in place.
    func testAnUnopenableReplacementIsStillAReplacement() throws {
        let parent = try tempDir()
        let folder = parent.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(ContainerRoot.revalidate(folder), .unchanged)
        let old = parent.appendingPathComponent("old")
        XCTAssertEqual(rename(folder.path, old.path), 0)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(folder.path, 0), 0)
        defer { chmod(folder.path, 0o755) }
        XCTAssertEqual(ContainerRoot.revalidate(folder), .replaced)
        XCTAssertEqual(ContainerRoot.revalidate(folder), .replaced, "still another folder at the path")
        guard case .anchored(let root) = ContainerRoot.shared(for: folder) else { return XCTFail("no anchor") }
        var st = stat()
        XCTAssertEqual(lstat(old.path, &st), 0)
        XCTAssertEqual(root.inode, UInt64(st.st_ino), "the unopenable folder was not anchored")
    }

    /// A folder is the anchored one only when both device and inode match:
    /// the same inode number on another volume is another folder.
    func testIdentityNeedsTheDeviceAndTheInode() throws {
        let folder = try tempDir()
        guard case .anchored(let root) = ContainerRoot.anchor(folder) else { return XCTFail("no anchor") }
        var st = stat()
        XCTAssertEqual(lstat(folder.path, &st), 0)
        XCTAssertTrue(root.isSame(as: st))
        var otherDevice = st
        otherDevice.st_dev &+= 1
        XCTAssertFalse(root.isSame(as: otherDevice))
        var otherInode = st
        otherInode.st_ino &+= 1
        XCTAssertFalse(root.isSame(as: otherInode))
    }

    /// Same folder, path not checkable: a refusal, never a replacement.
    func testAnUncheckablePathIsRefusedNotReplaced() throws {
        let parent = try tempDir()
        let folder = parent.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(ContainerRoot.revalidate(folder), .unchanged)
        XCTAssertEqual(chmod(parent.path, 0), 0)
        defer { chmod(parent.path, 0o755) }
        guard case .refused = ContainerRoot.revalidate(folder) else { return XCTFail("expected a refusal") }
    }

    func testOnlySingleComponentNamesAreUsed() throws {
        let dir = try tempDir()
        for name in ["..", ".", ""] {
            XCTAssertFalse(SafeFile.isPlainName(name), name)
        }
        XCTAssertFalse(SafeFile.isPlainName("a/b"))
        XCTAssertTrue(SafeFile.isPlainName("snapshot.json"))
        guard case .refused = SafeFile.read(dir.appendingPathComponent("..")) else { return XCTFail("..") }
    }

    /// A log whose lock is held elsewhere is skipped, never waited on.
    func testALogWithAHeldLockIsSkippedQuickly() throws {
        let dir = try tempDir()
        let log = dir.appendingPathComponent("reload-log.txt")
        let holder = SafeFile.openLock(URL(fileURLWithPath: log.path + ".lock"))
        XCTAssertGreaterThanOrEqual(holder, 0)
        XCTAssertEqual(flock(holder, LOCK_EX), 0)
        defer { close(holder) }
        let started = Date()
        try CappedLog.append("line", to: log, cap: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        XCTAssertEqual(SafeFile.read(log), .missing, "the entry was skipped")
    }

    /// A container folder that is itself a link to elsewhere is refused.
    func testAFileWhoseFolderLeadsOutsideTheRootIsRefused() throws {
        let root = try tempDir()
        let outside = try tempDir()
        try Data("x".utf8).write(to: outside.appendingPathComponent("a.json"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sub"), withDestinationURL: outside)
        guard case .refused = SafeFile.read(root.appendingPathComponent("sub/a.json")) else {
            return XCTFail("read through a linked folder")
        }
    }

    /// Writing over a link replaces the link; the file it pointed at is untouched.
    func testAWriteReplacesALinkAndNeverWritesThroughIt() throws {
        let dir = try tempDir()
        let secret = try sentinel("SENTINEL")
        let url = dir.appendingPathComponent("snapshot.json")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: secret)
        try SafeFile.write(Data("new".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "SENTINEL")
        var st = stat()
        XCTAssertEqual(lstat(url.path, &st), 0)
        XCTAssertTrue(SafeFile.isSingleRegular(st))
        XCTAssertEqual(SafeFile.read(url), .data(Data("new".utf8)))
    }

    /// Every store in the container refuses a link to a file it would
    /// otherwise accept.
    func testEveryContainerReaderRefusesALink() throws {
        let dir = try tempDir()
        func linked(_ name: String, to contents: String) throws {
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(name),
                                                       withDestinationURL: try sentinel(contents))
        }
        let snapshot = String(decoding: try SnapshotStore.encode(UsageSnapshot(writtenAt: Date(), providers: [])), as: UTF8.self)
        try linked(SharedContainer.snapshotFileName, to: snapshot)
        XCTAssertNil(SnapshotStore.read(from: dir.appendingPathComponent(SharedContainer.snapshotFileName)))
        try linked(RefreshRequestStore.fileName, to: #"{"requestedAt": 1790000000, "sequence": 3}"#)
        XCTAssertNil(RefreshRequestStore.read(in: dir))
        try linked(ReloadStateStore.fileName, to: String(decoding: try JSONEncoder().encode(ReloadState()), as: UTF8.self))
        guard case .unreadable = ReloadStateStore.read(from: dir.appendingPathComponent(ReloadStateStore.fileName)) else {
            return XCTFail("reload state read through a link")
        }
        try linked(WriterStateStore.fileName, to: #"{"lastSequence": 7}"#)
        XCTAssertNil(WriterStateStore.read(in: dir))
        try linked("reload-log.txt", to: "old line\n")
        XCTAssertThrowsError(try CappedLog.append("new", to: dir.appendingPathComponent("reload-log.txt"), cap: 10))
        try linked("agent.lock", to: "")
        guard case .failed = InstanceLock.acquire(at: dir.appendingPathComponent("agent.lock")).kind else {
            return XCTFail("lock opened through a link")
        }
    }

    func testTheStateReportRefusesALink() throws {
        let dir = try tempDir()
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(SharedContainer.snapshotFileName),
                                                   withDestinationURL: try sentinel("SENTINEL-CONTENTS"))
        let text = StateReport.text(in: dir, lines: 5)
        XCTAssertFalse(text.contains("SENTINEL-CONTENTS"))
        XCTAssertTrue(text.contains("--- snapshot.json\n(refused"), text)
    }

    /// The agent lock's holder pid goes through SafeFile on the locked
    /// descriptor itself: published, read back by a probe, and cleared.
    func testTheLockHolderPidIsWrittenReadAndClearedOnTheLockedFile() throws {
        let url = try tempDir().appendingPathComponent("agent.lock")
        let fd = SafeFile.openLock(url)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertNil(SafeFile.publishLockHolder(fd, pid: 4321))
        XCTAssertEqual(SafeFile.readLockHolder(fd), 4321)
        XCTAssertNil(SafeFile.publishLockHolder(fd, pid: 7), "a shorter pid replaces a longer one whole")
        XCTAssertEqual(SafeFile.readLockHolder(fd), 7)
        XCTAssertNil(SafeFile.clearLockHolder(fd))
        XCTAssertNil(SafeFile.readLockHolder(fd))
    }

    /// A pid that cannot be written is an error to log, not silence.
    func testAPidThatCannotBePublishedIsAnError() throws {
        let url = try tempDir().appendingPathComponent("agent.lock")
        XCTAssertGreaterThanOrEqual(SafeFile.openLock(url), 0)
        let readOnly = try XCTUnwrap(FileHandle(forReadingAtPath: url.path))
        defer { try? readOnly.close() }
        XCTAssertNotNil(SafeFile.publishLockHolder(readOnly.fileDescriptor, pid: 1))
    }

    /// The write itself failing (here: a zero file size limit, which lets
    /// the file be emptied but not written) is reported too.
    func testAFailedPidWriteIsAnError() throws {
        let url = try tempDir().appendingPathComponent("agent.lock")
        let fd = SafeFile.openLock(url)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var saved = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &saved), 0)
        let oldHandler = signal(SIGXFSZ, SIG_IGN)
        var zero = saved
        zero.rlim_cur = 0
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &zero), 0)
        let error = SafeFile.publishLockHolder(fd, pid: 4321)
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &saved), 0)
        signal(SIGXFSZ, oldHandler)
        XCTAssertNotNil(error)
    }

    /// No file is opened, read or written anywhere else: every such call
    /// in the package, the app and the widget sits in these files.
    func testFileAccessGoesThroughSafeFileOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()                           // Packages/UsageKit
        let repo = root.deletingLastPathComponent().deletingLastPathComponent()
        let folders = [root.appendingPathComponent("Sources"), repo.appendingPathComponent("App"),
                       repo.appendingPathComponent("Widget")]
        let pattern = /Data\(contentsOf|String\(contentsOf|FileHandle\(|\.createFile\(|fopen\(|(^|[^A-Za-z0-9_])open\(|openat\(|renameat\(|unlinkat\(|\.write\(to:|pread\(|pwrite\(|ftruncate\(/
        let allowed: Set<String> = ["SafeFile.swift"]
        var found: [String] = []
        for folder in folders {
            let files = FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? []
            for file in files where file.hasSuffix(".swift") {
                let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") && line.contains(pattern) {
                    let name = URL(fileURLWithPath: file).lastPathComponent
                    if !allowed.contains(name) { found.append("\(file):\(number + 1)") }
                }
            }
        }
        XCTAssertEqual(found, [], "file access outside SafeFile")
        XCTAssertGreaterThan(folders.count, 0)
    }
}

/// Write numbers: kept by the writer, range checked, adopted when higher.
final class WriteNumberTests: XCTestCase {
    let t0 = utc(2026, 9, 28, 12, 0, 0)

    func testAnOutOfRangeNumberMakesTheSnapshotCorrupt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("snapshot.json")
        for bad in [Int.max, -1, Int.max / 2] {
            try SnapshotStore.write(UsageSnapshot(writtenAt: t0, providers: [], writeSequence: bad), to: url)
            XCTAssertNil(SnapshotStore.read(from: url), "\(bad)")
            XCTAssertEqual(try SnapshotStore.writeNumbered(UsageSnapshot(writtenAt: t0, providers: []), to: url, after: nil).sequence,
                           1, "treated as missing: numbering starts at 1")
        }
        try Data(#"{"lastSequence": 9223372036854775807}"#.utf8).write(to: dir.appendingPathComponent(WriterStateStore.fileName))
        XCTAssertNil(WriterStateStore.read(in: dir))
    }

    /// The last valid number wraps to 1 under a new writer id in the same
    /// write, so a press waiting on the old writer is answered.
    func testTheLastValidNumberWrapsToOneUnderANewWriter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("snapshot.json")
        let last = WriterState.maxSequence - 1
        try SnapshotStore.write(UsageSnapshot(writtenAt: t0, providers: [], writeSequence: last, writerId: "OLD"), to: url)
        let request = RefreshRequest(requestedAt: t0, afterSnapshot: last, afterWriter: "OLD")
        let outcome = try SnapshotStore.writeNumbered(UsageSnapshot(writtenAt: t0, providers: [], writerId: "OLD"), to: url,
                                                      after: last)
        XCTAssertEqual(outcome.sequence, 1)
        XCTAssertNotEqual(outcome.writerId, "OLD")
        let written = try XCTUnwrap(SnapshotStore.read(from: url))
        XCTAssertEqual(written.writeSequence, 1)
        XCTAssertEqual(written.writerId, outcome.writerId)
        XCTAssertTrue(RefreshState.answers(written.mark, request))
    }

    func testAHigherNumberFromAnotherWriterIsAdopted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("snapshot.json")
        try SnapshotStore.write(UsageSnapshot(writtenAt: t0, providers: [], writeSequence: 9), to: url)
        let outcome = try SnapshotStore.writeNumbered(UsageSnapshot(writtenAt: t0, providers: []), to: url, after: 8)
        XCTAssertEqual(outcome.sequence, 10)
        XCTAssertEqual(outcome.adopted, 9)
        let own = try SnapshotStore.writeNumbered(UsageSnapshot(writtenAt: t0, providers: []), to: url, after: 10)
        XCTAssertEqual(own.sequence, 11)
        XCTAssertNil(own.adopted)
    }

    /// A press is answered by a snapshot from another writer (a restart),
    /// or by the same writer's next number.
    func testAnswersFollowTheWriterAndItsNumber() {
        let request = RefreshRequest(requestedAt: t0, afterSnapshot: 9, afterWriter: "A")
        XCTAssertTrue(RefreshState.answers(SnapshotMark(writer: "B", sequence: 1), request))
        XCTAssertTrue(RefreshState.answers(SnapshotMark(writer: "A", sequence: 10), request))
        XCTAssertFalse(RefreshState.answers(SnapshotMark(writer: "A", sequence: 9), request))
        XCTAssertFalse(RefreshState.answers(nil, request), "no snapshot yet")
    }
}
