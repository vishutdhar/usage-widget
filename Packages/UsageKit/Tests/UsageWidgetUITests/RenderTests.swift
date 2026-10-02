import AppKit
import SwiftUI
import XCTest
import UsageCore
@testable import UsageWidgetUI

/// Renders the widget views at real macOS widget sizes, in light and dark,
/// saves PNGs to `renders/` at the repository root (or `RENDER_DIR`) for a
/// person to look at, and compares each against an approved image in
/// `Approved/`. A missing word, a clipped row, or a changed colour moves far
/// more pixels than the tolerance allows.
///
/// After an intended visual change, look at the new PNGs in `renders/`, then
/// approve them with `APPROVE_RENDERS=1 swift test --filter RenderTests`.
/// Approved images follow the fonts of the Mac that approved them; another
/// macOS version may need a fresh approval.
@MainActor
final class RenderTests: XCTestCase {
    static let medium = CGSize(width: 329, height: 155)
    static let large = CGSize(width: 329, height: 345)
    /// The system's content margins around a widget's content.
    static let margin = 16.0

    /// Taken when each test starts. Every countdown is at least an hour and
    /// half a minute out, so its text cannot change during the test.
    nonisolated(unsafe) var now = Date()

    /// The entry date and every measurement time are fixed, so "as of" and
    /// "last known" text never changes between runs. Countdowns still count
    /// from the real clock, as relative date text always does.
    static let entryDate = ISODate.parse("2026-01-15T12:00:00Z")!

    override func setUp() {
        now = Date()
    }

    /// Differing pixels allowed, as a share of the image.
    static let tolerance = 0.0005
    /// A channel difference at or below this is antialiasing noise.
    static let channelSlack = 24

    // MARK: fixtures, relative to now so countdowns read naturally

    func window(_ kind: UsageWindow.Kind, _ name: String, _ pct: Double, in seconds: TimeInterval?,
                expected: Double? = nil) -> UsageWindow {
        UsageWindow(kind: kind, name: name, windowSeconds: kind == .session ? 18_000 : 604_800, usedPct: pct,
                    resetsAt: seconds.map { now.addingTimeInterval($0 + 30) }, expectedPct: expected,
                    aheadOfPace: expected.map { pct - $0 >= 15 })
    }

    /// Three sample accounts: one active and near its weekly limit, two at
    /// the limit of their model window.
    func sampleAccounts() -> [AccountUsage] {
        [
            AccountUsage(id: "1", label: "alex@example.com", active: true, fetchedAt: Self.entryDate, windows: [
                window(.session, "5h", 20, in: 4 * 3600),
                window(.weekly, "7d", 80, in: 33 * 3600, expected: 70),
                window(.model, "Fable", 100, in: 33 * 3600, expected: 70),
            ]),
            AccountUsage(id: "2", label: "sam@example.com", active: false, fetchedAt: Self.entryDate, windows: [
                window(.session, "5h", 0, in: nil),
                window(.weekly, "7d", 90, in: 80 * 3600, expected: 50),
                window(.model, "Fable", 100, in: 80 * 3600, expected: 50),
            ]),
            AccountUsage(id: "3", label: "jordan@example.com", active: false, fetchedAt: Self.entryDate, windows: [
                window(.session, "5h", 0, in: 4 * 3600),
                window(.weekly, "7d", 85, in: 106 * 3600, expected: 40),
                window(.model, "Fable", 100, in: 106 * 3600, expected: 40),
            ]),
        ]
    }

    func snapshot(_ accounts: [AccountUsage], status: ProviderUsage.Status = .ok, error: String? = nil,
                  writtenAgo: TimeInterval = 30) -> UsageSnapshot {
        UsageSnapshot(writtenAt: now.addingTimeInterval(-writtenAgo), providers: [
            ProviderUsage(provider: "claude", source: "cswap-list", status: status, error: error, accounts: accounts),
        ])
    }

    func content(_ snapshot: UsageSnapshot?) -> WidgetContent {
        WidgetContent.make(snapshot: snapshot, at: Self.entryDate)
    }

    // MARK: renders

    func testSampleDataMediumAndLarge() throws {
        let c = content(snapshot(sampleAccounts()))
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium")
            try render(c, .large, scheme, "large")
        }
    }

    func testErrorAndStale() throws {
        var accounts = sampleAccounts()
        for i in accounts.indices { accounts[i].fetchedAt = Self.entryDate.addingTimeInterval(-20 * 60) }
        let c = content(snapshot(accounts, status: .error, error: "cswap not found", writtenAgo: 60))
        XCTAssertEqual(WidgetContent.asOf(of: c.sections.flatMap(\.accounts)), Self.entryDate.addingTimeInterval(-20 * 60),
                       "the widget says when its numbers are from")
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-error-stale")
            try render(c, .large, scheme, "large-error-stale")
        }
    }

    /// The overnight case: every account measured hours ago and the agent
    /// not running. The bars keep their usage colours; each account says it
    /// is stale and when it was measured; the footer says the widget is not
    /// updating.
    func testStaleNumbersKeepTheirColours() throws {
        var accounts = sampleAccounts()
        for i in accounts.indices { accounts[i].fetchedAt = Self.entryDate.addingTimeInterval(-16 * 3600) }
        var snap = snapshot(accounts)
        snap.writtenAt = Self.entryDate.addingTimeInterval(-16 * 3600)
        let c = WidgetContent.make(snapshot: snap, at: Self.entryDate, refresh: nil, checkedAt: Self.entryDate)
        XCTAssertTrue(c.notUpdating)
        XCTAssertTrue(c.sections[0].accounts.allSatisfy { $0.staleSince != nil })
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-stale")
            try render(c, .large, scheme, "large-stale")
        }
    }

    /// Old numbers from an agent still writing: the footer dates them,
    /// "as of 8:00 PM yesterday", and the bars keep their colours.
    func testOldNumbersFromARunningAgentAreDatedInTheFooter() throws {
        var accounts = sampleAccounts()
        for i in accounts.indices { accounts[i].fetchedAt = Self.entryDate.addingTimeInterval(-16 * 3600) }
        var snap = snapshot(accounts)
        snap.writtenAt = Self.entryDate.addingTimeInterval(-60)
        let c = WidgetContent.make(snapshot: snap, at: Self.entryDate, refresh: nil, checkedAt: Self.entryDate)
        XCTAssertFalse(c.notUpdating)
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-stale-running")
        }
    }

    /// Without RENDER_DIR or APPROVE_RENDERS, PNGs go to a temporary folder,
    /// never into the repository.
    func testPlainRunsWriteRendersOutsideTheRepository() throws {
        let settings = ProcessInfo.processInfo.environment
        guard settings["RENDER_DIR"] == nil, settings["APPROVE_RENDERS"] == nil else {
            throw XCTSkip("an output folder was chosen for this run")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        XCTAssertFalse(Self.outputDirectory.path.hasPrefix(repository), Self.outputDirectory.path)
        XCTAssertTrue(Self.outputDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    /// A press of the refresh button being answered: the footer says so.
    func testRefreshing() throws {
        var c = content(snapshot(sampleAccounts()))
        c.refreshFooter = .refreshing
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-refreshing")
            try render(c, .large, scheme, "large-refreshing")
        }
    }

    /// A press answered at any cap: fresh numbers under the plain "as of".
    func testRefreshAnswered() throws {
        var c = content(snapshot(sampleAccounts()))
        c.refreshFooter = .none
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-refresh-answered")
            try render(c, .large, scheme, "large-refresh-answered")
        }
    }

    func testEmptyState() throws {
        for scheme in [ColorScheme.light, .dark] {
            try render(content(nil), .medium, scheme, "medium-empty")
        }
    }

    func testManyAccountsAndUnavailable() throws {
        var accounts = sampleAccounts()
        accounts.append(AccountUsage(id: "4", label: "casey@example.com", active: false, fetchedAt: nil, windows: []))
        accounts.append(AccountUsage(id: "5", label: "riley@example.com", active: false, fetchedAt: Self.entryDate, windows: [
            window(.session, "5h", 64, in: 2 * 3600), window(.weekly, "7d", 71, in: 50 * 3600, expected: 60),
        ]))
        accounts.append(AccountUsage(id: "6", label: "morgan@example.com", active: false, fetchedAt: Self.entryDate, windows: [
            window(.weekly, "7d", 12, in: 150 * 3600, expected: 10),
        ]))
        let c = content(snapshot(accounts))
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-many")
            try render(c, .large, scheme, "large-many")
        }
    }

    /// A sample Codex reading as the agent writes it: a Pro plan reports
    /// only a weekly window, and the app-server says two resets are banked.
    func codexProvider() -> ProviderUsage {
        ProviderUsage(provider: "codex", source: "app-server", status: .ok, accounts: [
            AccountUsage(id: "codex", label: "Codex", active: false, fetchedAt: Self.entryDate,
                         windows: [window(.weekly, "Weekly", 35, in: 70 * 3600)]),
        ], extras: ["resetCreditsAvailable": .number(2), "planType": .string("pro")])
    }

    func testCodexBesideTheClaudeAccounts() throws {
        var snap = snapshot(sampleAccounts())
        snap.providers.append(codexProvider())
        let c = content(snap)
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-codex")
            try render(c, .large, scheme, "large-codex")
        }
    }

    /// A failed app-server call over a rollout reading five hours old, on a
    /// plan with a five hour and a weekly window and no known reset count.
    func testCodexErrorAndStale() throws {
        var snap = snapshot(sampleAccounts())
        snap.providers.append(ProviderUsage(
            provider: "codex", source: "rollout", status: .error,
            error: "codex app-server did not answer within 20 s", accounts: [
                AccountUsage(id: "codex", label: "Codex", active: false,
                             fetchedAt: Self.entryDate.addingTimeInterval(-5 * 3600),
                             windows: [window(.session, "5h", 64, in: 2 * 3600),
                                       window(.weekly, "Weekly", 91, in: 30 * 3600)],
                             status: .stale, statusNote: "No new reading"),
            ], extras: ["resetCreditsAvailable": .null, "planType": .string("plus")]))
        let c = content(snap)
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-codex-issues")
            try render(c, .large, scheme, "large-codex-issues")
        }
    }

    func statusAccounts() -> [AccountUsage] {
        [
            AccountUsage(id: "1", label: "alex@example.com", active: true, fetchedAt: Self.entryDate, windows: [
                window(.session, "5h", 41, in: 2 * 3600),
                UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: nil,
                            resetsAt: now.addingTimeInterval(50 * 3600 + 30)),
                UsageWindow(kind: .spend, name: "Spend", windowSeconds: 0, usedPct: 80,
                            resetsAt: now.addingTimeInterval(90 * 3600 + 30), amount: 80, limit: 100, currency: "USD"),
            ]),
            AccountUsage(id: "2", label: "sam@example.com", active: false,
                         fetchedAt: Self.entryDate.addingTimeInterval(-26 * 3600), windows: [
                window(.weekly, "7d", 64, in: 70 * 3600, expected: 50),
            ], status: .reloginRequired, statusNote: "Log in again"),
            AccountUsage(id: "3", label: "jordan@example.com", active: false,
                         fetchedAt: Self.entryDate.addingTimeInterval(-2 * 3600), windows: [
                window(.session, "5h", 12, in: 2 * 3600),
                window(.weekly, "7d", 91, in: 30 * 3600, expected: 70),
            ], status: .stale, statusNote: "Token expired"),
            AccountUsage(id: "4", label: "casey@example.com", active: false, fetchedAt: nil, windows: [],
                         status: .unavailable, statusNote: "Keychain locked"),
        ]
    }

    func testStatusesSpendAndUnknown() throws {
        let c = content(snapshot(statusAccounts()))
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-statuses")
            try render(c, .large, scheme, "large-statuses")
        }
    }

    /// One account with 5h, 7d, eight model windows and spend, beside two others.
    func fullestAccounts() -> [AccountUsage] {
        var windows = [window(.session, "5h", 35, in: 2 * 3600), window(.weekly, "7d", 72, in: 40 * 3600, expected: 60)]
        for (index, pct) in [20.0, 70, 95, 40, 10, 5, 60, 30].enumerated() {
            windows.append(window(.model, "Model \(index + 1)", pct, in: 40 * 3600, expected: 60))
        }
        windows.append(UsageWindow(kind: .spend, name: "Spend", windowSeconds: 0, usedPct: 42,
                                   amount: 42, limit: 100, currency: "USD"))
        var accounts = sampleAccounts()
        accounts[0].windows = windows
        return accounts
    }

    /// Even the smallest layout each size falls back to must fit, whatever
    /// one account carries.
    func testTheFullestAccountFitsBothSizes() throws {
        let c = content(snapshot(fullestAccounts()))
        for (size, frame) in [(UsageWidgetSize.medium, Self.medium), (.large, Self.large)] {
            let width = frame.width - 2 * Self.margin
            let available = frame.height - 2 * Self.margin
            let tightest = UsageWidgetView.tightestLayout(content: c, size: size)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.locale, Self.locale)
            let height = NSHostingController(rootView: tightest).sizeThatFits(in: CGSize(width: width, height: 10_000)).height
            XCTAssertLessThanOrEqual(height, available, "\(size): the tightest layout needs \(height) pt of \(available)")
        }
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-fullest")
            try render(c, .large, scheme, "large-fullest")
        }
    }

    /// The fullest account beside Codex: even the tightest layout of each
    /// size keeps Codex, and fits.
    func testTheFullestAccountWithCodexFitsAndKeepsCodex() throws {
        var snap = snapshot(fullestAccounts())
        snap.providers.append(codexProvider())
        let c = content(snap)
        for (size, frame) in [(UsageWidgetSize.medium, Self.medium), (.large, Self.large)] {
            let width = frame.width - 2 * Self.margin
            let available = frame.height - 2 * Self.margin
            let tightest = UsageWidgetView.tightestLayout(content: c, size: size)
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.locale, Self.locale)
            let height = NSHostingController(rootView: tightest).sizeThatFits(in: CGSize(width: width, height: 10_000)).height
            XCTAssertLessThanOrEqual(height, available, "\(size): the tightest layout needs \(height) pt of \(available)")
        }
        for scheme in [ColorScheme.light, .dark] {
            try render(c, .medium, scheme, "medium-fullest-codex")
            try render(c, .large, scheme, "large-fullest-codex")
            // The large widget's last resort, drawn directly: Codex on one line.
            try render(c, .large, scheme, "large-last-resort-codex", tightest: true)
        }
    }

    /// Amounts and times follow the SwiftUI environment's locale, not the
    /// process's: the same content drawn for another locale looks different.
    func testFormattingFollowsTheEnvironmentLocale() throws {
        let c = content(snapshot(statusAccounts()))
        let posix = try image(c, .large, .light, locale: Self.locale)
        let german = try image(c, .large, .light, locale: Locale(identifier: "de_DE"))
        XCTAssertGreaterThan(Self.differingPixels(posix, german), 100)
    }

    /// Each formatted element on its own, so a single one that ignored the
    /// environment would be caught: spend text, a note's last known time,
    /// and the "as of" line.
    func testEachFormattedElementReadsTheEnvironment() throws {
        let spend = UsageDisplay.row(for: UsageWindow(kind: .spend, name: "Spend", windowSeconds: 0, usedPct: 42,
                                                      amount: 1234.5, limit: 5000, currency: "EUR"), at: Self.entryDate)
        let spendRow = Grid { WindowRowView(row: spend, reservesMarker: false) }.frame(width: 297)
        XCTAssertGreaterThan(try differing(spendRow, "de_DE"), 20, "spend text")

        let noted = WidgetContent.Account(id: "2", label: "sam@example.com", active: false, rows: [],
                                          note: "Log in again", lastKnownAt: Self.entryDate.addingTimeInterval(-26 * 3600))
        // Alone in a Grid its unsized cell collapses; a stack gives it the full width.
        let noteRow = VStack { NoteRow(account: noted, now: Self.entryDate) }.frame(width: 600)
        XCTAssertGreaterThan(try differing(noteRow, "de_DE"), 20, "note line")

        let quiet = UsageSnapshot(writtenAt: Self.entryDate, providers: [
            ProviderUsage(provider: "claude", source: "x", status: .ok, accounts: [
                AccountUsage(id: "1", label: "a", active: true, fetchedAt: Self.entryDate, windows: [
                    UsageWindow(kind: .weekly, name: "7d", windowSeconds: 604_800, usedPct: nil),
                ]),
            ]),
        ])
        let widget = UsageWidgetView(content: content(quiet), size: .medium).frame(width: 297, height: 123)
        XCTAssertGreaterThan(try differing(widget, "de_DE"), 20, "as of line")
    }

    /// Pixels that differ between drawing `view` in the pinned locale and in
    /// `other`.
    func differing<V: View>(_ view: V, _ other: String) throws -> Int {
        func draw(_ locale: Locale) throws -> CGImage {
            let renderer = ImageRenderer(content: view
                .environment(\.locale, locale)
                .environment(\.timeZone, Self.timeZone)
                .environment(\.calendar, Self.calendar))
            renderer.scale = 2
            return try XCTUnwrap(renderer.cgImage)
        }
        return Self.differingPixels(try draw(Self.locale), try draw(Locale(identifier: other)))
    }

    // MARK: rendering

    /// The harness pins these through the environment so approvals do not
    /// depend on the Mac's settings; production keeps the person's own.
    static let locale = Locale(identifier: "en_US")
    static let timeZone = TimeZone(identifier: "UTC")!
    static let calendar = Calendar(identifier: .gregorian)

    /// - Parameter tightest: draw the size's last-resort layout instead of
    ///   the one the widget would pick.
    func image(_ content: WidgetContent, _ size: UsageWidgetSize, _ scheme: ColorScheme,
               locale: Locale = RenderTests.locale, tightest: Bool = false) throws -> CGImage {
        let frame = size == .medium ? Self.medium : Self.large
        let body: AnyView = tightest
            ? AnyView(UsageWidgetView.tightestLayout(content: content, size: size))
            : AnyView(UsageWidgetView(content: content, size: size, refreshControl: AnyView(RefreshButtonLabel())))
        let view = body
            .padding(Self.margin)
            .frame(width: frame.width, height: frame.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, scheme)
            .environment(\.locale, locale)
            .environment(\.timeZone, Self.timeZone)
            .environment(\.calendar, Self.calendar)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    func render(_ content: WidgetContent, _ size: UsageWidgetSize, _ scheme: ColorScheme, _ name: String,
                tightest: Bool = false) throws {
        let frame = size == .medium ? Self.medium : Self.large
        let image = try image(content, size, scheme, tightest: tightest)
        XCTAssertEqual(image.width, Int(frame.width * 2), name)
        XCTAssertEqual(image.height, Int(frame.height * 2), name)
        XCTAssertGreaterThan(distinctColors(image), 20, "\(name) looks blank")

        let file = "\(name)-\(scheme == .dark ? "dark" : "light").png"
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: Self.outputDirectory.appendingPathComponent(file))
        try compare(image, toApproved: Self.approvedDirectory.appendingPathComponent(file), png: png)
    }

    func compare(_ image: CGImage, toApproved url: URL, png: Data) throws {
        if ProcessInfo.processInfo.environment["APPROVE_RENDERS"] == "1" {
            try FileManager.default.createDirectory(at: Self.approvedDirectory, withIntermediateDirectories: true)
            try png.write(to: url)
            return
        }
        guard let approvedData = try? Data(contentsOf: url),
              let approved = NSBitmapImageRep(data: approvedData)?.cgImage
        else {
            return XCTFail("no approved image \(url.lastPathComponent); check renders/ and approve with APPROVE_RENDERS=1")
        }
        XCTAssertEqual(approved.width, image.width, url.lastPathComponent)
        XCTAssertEqual(approved.height, image.height, url.lastPathComponent)
        let differing = Self.differingPixels(image, approved)
        let share = Double(differing) / Double(image.width * image.height)
        XCTAssertLessThanOrEqual(share, Self.tolerance,
                                 "\(url.lastPathComponent): \(differing) pixels differ from the approved image")
    }

    /// Pixels where any channel differs by more than `channelSlack`, after
    /// drawing both images into the same RGBA format.
    static func differingPixels(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return a.width * a.height }
        func rgba(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let x = rgba(a), y = rgba(b)
        var count = 0
        for pixel in stride(from: 0, to: x.count, by: 4) {
            for channel in 0..<4 where abs(Int(x[pixel + channel]) - Int(y[pixel + channel])) > channelSlack {
                count += 1
                break
            }
        }
        return count
    }

    static let approvedDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Approved", isDirectory: true)

    func distinctColors(_ image: CGImage) -> Int {
        let rep = NSBitmapImageRep(cgImage: image)
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5
                    | UInt32(c.blueComponent * 31)
                seen.insert(key)
            }
        }
        return seen.count
    }

    /// Where the PNGs go: RENDER_DIR when set; the repository's renders/
    /// only when approving (APPROVE_RENDERS=1); otherwise a temporary
    /// folder, so a plain `swift test` leaves the repository untouched.
    static let outputDirectory: URL = {
        let settings = ProcessInfo.processInfo.environment
        let url: URL
        if let override = settings["RENDER_DIR"] {
            url = URL(fileURLWithPath: override, isDirectory: true)
        } else if settings["APPROVE_RENDERS"] == "1" {
            // Packages/UsageKit/Tests/UsageWidgetUITests/RenderTests.swift -> repository root
            url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("renders", isDirectory: true)
        } else {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-widget-renders", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
