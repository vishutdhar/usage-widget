import XCTest
@testable import UsageCore

final class InstanceLockTests: XCTestCase {
    func testOnlyOneHolderAtATime() throws {
        let url = try temporaryDirectory().appendingPathComponent("agent.lock")
        var first: InstanceLock? = InstanceLock.acquire(at: url).lock
        XCTAssertNotNil(first)
        XCTAssertEqual(InstanceLock.acquire(at: url).kind, .heldElsewhere, "a second agent must not start polling")
        first = nil
        XCTAssertNotNil(InstanceLock.acquire(at: url).lock, "released when the holder goes away")
    }

    func testAnotherProcessHoldingTheLockIsSeen() throws {
        let url = try temporaryDirectory().appendingPathComponent("agent.lock")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", "use Fcntl ':flock'; open(F, '>>', $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print \"locked\\n\"; sleep 5", url.path]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { holder.terminate() }
        _ = out.fileHandleForReading.availableData  // wait for "locked"
        XCTAssertEqual(InstanceLock.acquire(at: url).kind, .heldElsewhere)
    }

    /// Anything other than "someone else holds it" is an error to show,
    /// not a reason to hand over to an instance that does not exist.
    func testALockThatCannotBeOpenedIsAnError() throws {
        let url = try temporaryDirectory().appendingPathComponent("agent.lock")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard case .failed(let reason) = InstanceLock.acquire(at: url).kind else {
            return XCTFail("a directory in place of the lock file must be an error")
        }
        XCTAssertEqual(reason, "Is a directory")
    }

    /// A lock file that opens but cannot be locked (a FIFO does not support
    /// flock) is an error too, not a sign of another instance.
    func testALockThatCannotBeTakenIsAnError() throws {
        let url = try temporaryDirectory().appendingPathComponent("agent.lock")
        XCTAssertEqual(mkfifo(url.path, 0o644), 0)
        XCTAssertEqual(InstanceLock.acquire(at: url).kind, .failed("Inappropriate file type or format"),
                       "refused before flock: not a regular file")
    }
}

final class NewerSnapshotTests: XCTestCase {
    let t0 = utc(2026, 9, 27, 12, 0, 0)

    func snapshot(at date: Date, pct: Double) -> UsageSnapshot {
        UsageSnapshot(writtenAt: date, providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .ok, accounts: [
                AccountUsage(id: "1", label: "a", active: true, fetchedAt: date, windows: [
                    UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: pct),
                ]),
            ]),
        ])
    }

    func stored(at date: Date, sequence: Int?, to url: URL) throws {
        var s = snapshot(at: date, pct: 50)
        s.writeSequence = sequence
        try SnapshotStore.write(s, to: url)
    }

    /// The writer's own last file is replaced and numbered on, even when a
    /// small clock correction dates it after the new one.
    func testTheWritersOwnFileIsReplacedWhateverItsClock() throws {
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        try stored(at: t0.addingTimeInterval(300), sequence: 5, to: url)
        XCTAssertEqual(try SnapshotStore.writeNumbered(snapshot(at: t0, pct: 10), to: url, after: 5).sequence, 6)
        XCTAssertEqual(SnapshotStore.read(from: url)?.writtenAt, t0)
        XCTAssertEqual(SnapshotStore.read(from: url)?.writeSequence, 6)
    }

    func testAFileFromBeforeNumberingIsReplaced() throws {
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        try stored(at: t0.addingTimeInterval(300), sequence: nil, to: url)
        XCTAssertEqual(try SnapshotStore.writeNumbered(snapshot(at: t0, pct: 10), to: url, after: nil).sequence, 1)
    }

    func testNoFileIsWritten() throws {
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        XCTAssertEqual(try SnapshotStore.writeNumbered(snapshot(at: t0, pct: 10), to: url, after: nil).sequence, 1)
    }
}

final class RedactorTests: XCTestCase {
    func testEmailsKeepThreeCharactersAndTheTopLevelDomain() {
        XCTAssertEqual(Redactor.redactEmails("No login for alexander1993@example.com"), "No login for ale***@***.com")
        XCTAssertEqual(Redactor.redactEmails("a.b@x.co.uk and ab@y.io"), "a.b***@***.uk and ab***@***.io")
    }

    func testQuotedAndPlusAddressedLocalParts() {
        XCTAssertEqual(Redactor.redactEmails(#"to "john doe"@example.com now"#), "to ***@***.com now",
                       "a quoted local part keeps nothing")
        XCTAssertEqual(Redactor.redactEmails("alex+work@example.com failed"), "ale***@***.com failed")
        XCTAssertEqual(Redactor.redactEmails("(someone@example.org)"), "(som***@***.org)")
    }

    func testEscapedQuotesInsideAQuotedLocalPartDoNotLeak() {
        let text = #"denied for "john\"doe"@example.com"#
        let masked = Redactor.redactEmails(text)
        XCTAssertFalse(masked.contains("john"), masked)
        XCTAssertFalse(masked.contains("doe"), masked)
        XCTAssertFalse(masked.contains("joh"), masked)
        XCTAssertEqual(masked, "denied for ***@***.com")
    }

    func testEveryTextFieldOfAWrittenSnapshotIsMasked() throws {
        let snapshot = UsageSnapshot(writtenAt: utc(2026, 9, 27), providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: .error,
                          error: "cswap: no login for alex+work@example.com", accounts: [
                AccountUsage(id: "1", label: "alex@example.com", active: true, fetchedAt: nil, windows: [],
                             status: .unavailable, statusNote: "Usage unavailable (sam@example.com)"),
            ]),
        ])
        let url = try temporaryDirectory().appendingPathComponent("snapshot.json")
        try SnapshotStore.write(snapshot, to: url)
        let read = try XCTUnwrap(SnapshotStore.read(from: url))
        let provider = try read.providers[at: 0]
        XCTAssertEqual(provider.error, "cswap: no login for ale***@***.com")
        XCTAssertEqual(try provider.accounts[at: 0].statusNote, "Usage unavailable (sam***@***.com)")
        XCTAssertEqual(try provider.accounts[at: 0].label, "alex@example.com", "the label is what the widget is for")
    }

    func testCswapsUsageErrorIsMaskedInTheStatusNote() {
        let (_, note) = CswapListMapper.accountStatus(
            cswapStatus: "unavailable", hasUsage: false, lastKnown: false, usageError: "denied for someone@example.com")
        XCTAssertEqual(note, "Usage unavailable (denied for som***@***.com)")
    }

    func testTextWithoutEmailsIsUnchanged() {
        XCTAssertEqual(Redactor.redactEmails("cswap exited with code 2"), "cswap exited with code 2")
        XCTAssertEqual(Redactor.redactEmails("not an @ address"), "not an @ address")
    }
}
