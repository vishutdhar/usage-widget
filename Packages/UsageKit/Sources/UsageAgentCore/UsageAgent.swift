import Foundation
import UsageCore

/// What the status window shows about the background budget.
public struct BudgetStatus: Equatable, Sendable {
    public var cap: Int
    /// Requests in the trailing 24 hours.
    public var requests24h: Int
    /// The earliest an ordinary change could be requested.
    public var nextOrdinary: Date
    /// Whole tokens in the reload bucket, of `ReloadBucket.capacity`.
    public var tokens: Int = 0
    /// When the bucket's next token arrives; nil when it is full.
    public var nextToken: Date?
}

public struct TickReport: Equatable, Sendable {
    public var writtenAt: Date
    public var status: ProviderUsage.Status
    public var error: String?
    /// Empty when no reload was requested.
    public var reloadReasons: [ReloadReason]
    /// A visible change is waiting for the scheduler to allow a reload.
    public var pending = false
    /// Set while the scheduler's memory cannot be read or saved.
    public var stateError: String?
    /// Runs since launch where cswap left a helper holding its output.
    public var helperWarnings = 0
    /// Set when the snapshot could not be written.
    public var writeError: String?
    /// Why the last Codex app-server call failed, while it stands.
    public var codexError: String?
    /// When the app-server was last called, and the earliest the next
    /// call could go.
    public var codexCheckedAt: Date?
    public var codexNextCheck: Date?
    /// Set while the Codex call log cannot be read or saved.
    public var codexCallsError: String?
    /// The background budget, for the status window.
    public var budget: BudgetStatus?
    /// Set when the container was replaced at its path: the agent has
    /// stopped polling and writing for good (`error` says what to do).
    public var containerChanged = false
}

/// One poll: run cswap, build the next snapshot, and write it atomically.
/// Writing happens every poll, so the snapshot's age shows the agent is
/// alive. Reloading is a separate decision: the `ReloadScheduler`, whose
/// memory is persisted beside the snapshot, spends WidgetKit's small daily
/// budget only on changes a person would notice.
public actor UsageAgent {
    public let directory: URL
    private let runner: any CswapRunning
    private let reload: @Sendable () -> Void
    private let clock: @Sendable () -> SchedulerClock
    /// Saves the reload state; tests pass one that fails on demand.
    private let saveState: @Sendable (ReloadState, URL) throws -> Void
    /// This agent's last write number, kept in writer-state.json; at launch
    /// the higher of that and the snapshot's.
    private var lastWriteSequence: Int?
    /// Drawn at each launch and written into every snapshot; drawn again
    /// when the write numbers wrap.
    private var writerId = UUID().uuidString
    public var currentWriterId: String { writerId }
    private var loggedAdoption = false
    private var previous: UsageSnapshot?
    private var reloadState = ReloadState()
    /// What is on disk; the state is dirty while it differs.
    private var savedState: ReloadState?
    /// Set while the state cannot be read or saved; reloads are then
    /// limited to one an hour, tracked in memory.
    private var stateError: String?
    private var loaded = false
    private var helperWarnings = 0
    /// The session and number of the last press seen; presses on disk at
    /// launch are old.
    private var lastSeenRefresh: (session: String, sequence: Int)
    /// The newest press answered, which every snapshot written carries
    /// (`UsageSnapshot.answeredPress`): a press's poll names the press it
    /// measured for, any other write carries this forward. At launch, the
    /// press on disk (old, so counted as answered), else the snapshot's.
    private var answeredPress: AnsweredPress?
    private let pressAtLaunch: AnsweredPress?
    /// A press's completion reload: at most one this often.
    public static let pressReloadSpacing: TimeInterval = 10 * 60
    private var lastUserRefresh: SchedulerClock?
    /// The press being answered: its time tells whether the intent was
    /// still waiting when the answer was written.
    private var takenRequest: RefreshRequest?
    /// When this process started, as the scheduler measures time.
    private let launch: SchedulerClock

    private var codex: (any CodexSourcing)?
    /// The Codex reading shown: never re-dated, aged by the continuous
    /// clock. A live app-server answer always replaces it; a rollout event
    /// only when strictly newer than it.
    private var codexCurrent: RememberedReading?
    private var codexAppServerError: String?
    /// The app-server calls of the last day, kept on disk.
    private var codexCalls = CodexCallLog()
    /// Set while the call log cannot be read or saved.
    private var codexCallsError: String?
    /// A call has been made, or counted, since launch (or since Codex was
    /// turned on).
    private var codexCalledThisLaunch = false
    /// When the app-server last answered; kept in the snapshot's extras.
    private var codexAppServerCheckedAt: Date?

    /// Set once the container was replaced at its path: nothing runs or is
    /// written after that.
    private var stopped = false
    /// The container path could not be checked, and that has been logged.
    private var loggedUncheckable = false

    public init(
        directory: URL,
        runner: any CswapRunning,
        reload: @escaping @Sendable () -> Void,
        clock: @escaping @Sendable () -> SchedulerClock = { SchedulerClock.now() },
        codex: (any CodexSourcing)? = nil,
        saveState: @escaping @Sendable (ReloadState, URL) throws -> Void = { try ReloadStateStore.write($0, to: $1) }
    ) {
        self.codex = codex
        self.saveState = saveState
        self.directory = directory
        self.runner = runner
        self.reload = reload
        self.clock = clock
        self.launch = clock()
        let onDisk = RefreshRequestStore.read(in: directory)
        self.lastSeenRefresh = (onDisk?.session ?? "", onDisk?.sequence ?? 0)
        self.pressAtLaunch = onDisk.map(AnsweredPress.init)
    }

    /// A press numbered past the last one seen in its session (a new
    /// session counts from 0).
    private func isUnseen(_ request: RefreshRequest) -> Bool {
        request.sequence > (request.session == lastSeenRefresh.session ? lastSeenRefresh.sequence : 0)
    }

    /// Turns Codex reading on (with a source) or off (nil). Off hides the
    /// block (it stays in the snapshot, marked hidden) and stops polling but
    /// keeps what was read; on shows it again and asks the app-server only
    /// if the day's ceiling allows.
    public func setCodex(_ source: (any CodexSourcing)?) {
        codex = source
        if source != nil { codexCalledThisLaunch = false }
    }

    /// The codex provider block for this poll, or nil when Codex is off.
    /// The Codex step up to its merge: the rollout read and, when the
    /// policy allows, an app-server call. Nil while Codex is off (or turned
    /// off during the call). The caller merges at the moment it dates the
    /// snapshot, so Codex's age and the snapshot's date share one reading.
    private func codexStep(now stamp: SchedulerClock) async -> (codex: any CodexSourcing, rollout: CodexReading?)? {
        guard let codex else { return nil }
        let rollout = codex.rolloutReading(now: stamp.wall)
        if CodexCallPolicy.reason(calls: codexCalls.calls, firstOfLaunch: !codexCalledThisLaunch,
                                  newestRollout: rollout?.measuredAt, now: stamp) != nil {
            codexCalledThisLaunch = true
            // No call goes unless it is on disk first.
            if recordCodexCall(stamp) {
                await askCodexAppServer(codex)
                // Show Codex may have been turned off while the call was out:
                // then the block stays hidden.
                guard self.codex != nil else { return nil }
            }
        }
        return (codex, rollout)
    }

    private func askCodexAppServer(_ codex: any CodexSourcing) async {
        switch await codex.appServerReading() {
        case .success(var reading):
            // A live answer is newer than anything cached, whatever the
            // wall clock says.
            reading.planType = reading.planType ?? codexCurrent?.reading.planType
            reading.resetCreditsAvailable = reading.resetCreditsAvailable ?? codexCurrent?.reading.resetCreditsAvailable
            codexCurrent = RememberedReading(reading, at: clock())
            codexAppServerCheckedAt = reading.measuredAt
            codexAppServerError = nil
        case .failure(let failure):
            codexAppServerError = failure.reason
        }
    }

    private func mergeCodex(_ codex: any CodexSourcing, rollout: CodexReading?, readAt stamp: SchedulerClock,
                            now: SchedulerClock) -> ProviderUsage {
        // A rollout event replaces the cached reading only when its own time
        // is strictly newer than the cache's own time; neither is ever
        // re-dated, so a clock set back cannot let an older event in.
        if let rollout, codexCurrent.map({ rollout.measuredAt > $0.reading.measuredAt }) ?? true {
            var next = rollout
            next.resetCreditsAvailable = codexCurrent?.reading.resetCreditsAvailable
            next.planType = rollout.planType ?? codexCurrent?.reading.planType
            codexCurrent = RememberedReading(next, at: stamp)
        }
        return CodexMerge.block(rollout: nil, appServer: nil, lastKnown: codexCurrent?.reading(at: now),
                                appServerCheckedAt: codexAppServerCheckedAt, appServerError: codexAppServerError,
                                codexFound: codex.codexFound, now: now.wall)
    }

    /// The codex block of a snapshot as a reading, so a restart starts from
    /// what was shown: windows, plan, reset count and measurement time.
    static func lastKnownCodex(in snapshot: UsageSnapshot?) -> CodexReading? {
        guard let block = snapshot?.provider(CodexMerge.provider), let account = block.accounts.first,
              let measured = account.fetchedAt, !account.windows.isEmpty else { return nil }
        var plan: String?
        if case .string(let raw)? = block.extras[ProviderDetails.planKey] { plan = raw }
        return CodexReading(source: CodexReading.Source(rawValue: block.source) ?? .rollout, measuredAt: measured,
                            windows: account.windows, planType: plan,
                            resetCreditsAvailable: ProviderDetails.resetCredits(in: block.extras))
    }

    /// Logs a call before it is made, so even a call that hangs counts.
    /// False when the log could not be written: then the call must not go.
    private func recordCodexCall(_ stamp: SchedulerClock) -> Bool {
        var next = codexCalls
        next.calls = CodexCallPolicy.recent(codexCalls.calls, now: stamp) + [stamp]
        guard saveCodexCalls(next) else { return false }
        codexCalls = next
        return true
    }

    @discardableResult
    private func saveCodexCalls(_ log: CodexCallLog) -> Bool {
        do {
            try CodexCallLogStore.write(log, to: codexCallsURL)
            codexCallsError = nil
            return true
        } catch {
            codexCallsError = "Codex call log could not be saved: \(Redactor.redactEmails(error.localizedDescription))"
            return false
        }
    }

    /// Reads the call log once per launch and writes it straight back.
    /// A log that is corrupt or from another version counts as a full day
    /// (eight calls now). With no log, a snapshot whose Codex numbers came
    /// from the app-server within the day (the 15 minute build kept no log)
    /// counts that day as full from that answer. If the log cannot be
    /// written the agent is in the reload scheduler's conservative mode:
    /// the launch itself counts as a call, and no call goes until the log
    /// can be written.
    private func loadCodexCalls(previous: UsageSnapshot?) {
        switch CodexCallLogStore.read(from: codexCallsURL) {
        case .loaded(let log):
            codexCalls = log
        case .missing:
            // An answer older than a day falls outside the policy's window by itself.
            if let answered = Self.lastAppServerAnswer(in: previous) {
                let at = SchedulerClock(wall: min(answered, launch.wall), continuous: 0, boot: nil)
                codexCalls = CodexCallLog(calls: Array(repeating: at, count: CodexCallPolicy.dailyCeiling))
            }
        case .unreadable:
            codexCalls = CodexCallLog(calls: Array(repeating: launch, count: CodexCallPolicy.dailyCeiling))
        }
        if !saveCodexCalls(codexCalls) {
            codexCalls.calls.append(launch)
            codexCalledThisLaunch = true
        }
    }

    /// When the app-server last answered, as the snapshot tells it: the
    /// recorded answer time; else, for a snapshot from before it was
    /// recorded, the codex block's measurement time, whatever its source or
    /// reset count (that build asked every 15 minutes).
    static func lastAppServerAnswer(in snapshot: UsageSnapshot?) -> Date? {
        guard let block = snapshot?.provider(CodexMerge.provider) else { return nil }
        if case .string(let text)? = block.extras[CodexMerge.appServerCheckedAtKey], let date = ISODate.parse(text) {
            return date
        }
        return block.accounts.first?.fetchedAt
    }

    public var codexCallsURL: URL { directory.appendingPathComponent(CodexCallLogStore.fileName) }
    public var snapshotURL: URL { directory.appendingPathComponent(SharedContainer.snapshotFileName) }
    public var reloadLogURL: URL { directory.appendingPathComponent(SharedContainer.agentLogFileName) }
    public var reloadStateURL: URL { directory.appendingPathComponent(ReloadStateStore.fileName) }

    /// Shown in the status window once the agent has stopped because its
    /// container was replaced.
    public static let containerReplacedMessage = "The data folder was replaced. Quit and reopen Usage Widget."

    /// Presses within this long of the last one handled are ignored.
    public static let refreshDebounce: TimeInterval = 30

    /// True once for each new press of the refresh button: a request
    /// numbered past the last one seen (and past any on disk at launch),
    /// and not within `refreshDebounce` of the last one handled, on the
    /// continuous clock. The caller then runs `tick(userRequested: true)`.
    /// A scheduled poll takes a waiting press itself (`pressToAnswer`).
    public func takeRefreshRequest() -> Bool {
        guard !stopped, let request = RefreshRequestStore.read(in: directory) else { return false }
        // A new session (the file was deleted or damaged) counts from 0.
        guard isUnseen(request) else { return false }
        // A press is marked seen only once a snapshot answering it is
        // written; until then it stays pending and is looked at again. One
        // already taken and waiting for its poll is left to that poll.
        if let taken = takenRequest, taken.session == request.session, taken.sequence == request.sequence {
            return false
        }
        let stamp = clock()
        if let last = lastUserRefresh, stamp.seconds(since: last) < Self.refreshDebounce {
            // No second cswap run so soon, but the press is answered: the
            // last snapshot again under the next number, so the intent's
            // wait ends and its reload clears "Refreshing".
            if answerWithTheLastSnapshot(request, at: stamp) {
                lastSeenRefresh = (request.session, request.sequence)
            }
            return false
        }
        lastUserRefresh = stamp
        takenRequest = request
        return true
    }

    public func tick() async -> TickReport {
        await tick(userRequested: false)
    }

    /// Writes the last snapshot again under the next write number, naming
    /// the press as answered, and logs it. Through the same
    /// container check as a poll. A press noticed too late for its intent
    /// to see the answer also gets the counted completion reload. False
    /// when nothing could be written.
    private func answerWithTheLastSnapshot(_ request: RefreshRequest, at stamp: SchedulerClock) -> Bool {
        guard containerUsable(), var last = previous else { return false }
        last.writerId = writerId
        last.answeredPress = AnsweredPress(request)
        guard let outcome = try? SnapshotStore.writeNumbered(last, to: snapshotURL, after: lastWriteSequence) else { return false }
        answeredPress = last.answeredPress
        lastWriteSequence = outcome.sequence
        last.writeSequence = outcome.sequence
        if let id = outcome.writerId {
            writerId = id
            last.writerId = id
        }
        try? WriterStateStore.write(WriterState(lastSequence: outcome.sequence), in: directory)
        previous = last
        try? CappedLog.append("\(ISODate.format(stamp.wall)) refresh press within 30 s of the last; answered with the last snapshot",
                              to: reloadLogURL, cap: SharedContainer.logCap)
        if stamp.wall.timeIntervalSince(request.requestedAt) >= RefreshRequestStore.intentWait - RefreshRequestStore.intentPoll,
           let candidate = completionCandidate(reloadState, current: DisplayFingerprint(last), stamp: stamp,
                                               conservative: stateError != nil) {
            if persistState(candidate.state) {
                reloadState = candidate.state
                reload()
                let requests24h = candidate.state.requests.filter { stamp.seconds(since: $0) < ReloadScheduler.capWindow }.count
                let status = last.provider(CswapListMapper.provider)?.status.rawValue ?? ProviderUsage.Status.error.rawValue
                try? CappedLog.append(ReloadLog.line(at: stamp.wall, reasons: candidate.reasons, urgent: true, status: status,
                                                     requests24h: requests24h, id: candidate.id, kind: .press),
                                      to: reloadLogURL, cap: SharedContainer.logCap)
            }
        }
        return true
    }

    /// Every save of the reload state goes through here: a save that works
    /// records what is on disk and clears the error shown; one that fails
    /// sets it (and the conservative mode with it).
    @discardableResult
    private func persistState(_ state: ReloadState) -> Bool {
        do {
            try saveState(state, reloadStateURL)
            savedState = state
            stateError = nil
            return true
        } catch {
            stateError = "Reload state could not be saved: \(Redactor.redactEmails(error.localizedDescription))"
            return false
        }
    }

    /// The one check before anything is written: false once the agent has
    /// stopped, and it stops when another folder now sits at the
    /// container's path. A path that cannot be checked is logged once and
    /// the anchor goes on being used.
    private func containerUsable() -> Bool {
        if stopped { return false }
        switch ContainerRoot.revalidate(directory) {
        case .replaced:
            stopped = true
            return false
        case .refused(let reason):
            if !loggedUncheckable {
                loggedUncheckable = true
                try? CappedLog.append("\(ISODate.format(clock().wall)) container path could not be checked: "
                                      + Redactor.redactEmails(reason), to: reloadLogURL, cap: SharedContainer.logCap)
            }
        case .unchanged, .missing:
            loggedUncheckable = false
        }
        return true
    }

    /// A press's completion reload, for a press whose answer came after the
    /// intent's last look, when its gates allow: under the ceiling, a token
    /// in the reload bucket (or one borrowed: an empty bucket lends one,
    /// repaid by the next refill), at most one every 10 minutes, and inside
    /// the conservative hour when the state cannot be saved. It takes the
    /// token and counts like a background reload, so presses cannot push the
    /// day past WidgetKit's budget; while a debt is owed it does not go, and
    /// the change it would show is left to the background scheduler, which
    /// shows it with the next token. It starts the background spacing and
    /// records what it shows.
    private func completionCandidate(_ state: ReloadState, current: DisplayFingerprint, stamp: SchedulerClock,
                                     conservative: Bool) -> (state: ReloadState, id: Int, reasons: [ReloadReason])? {
        var press = state
        press.requests = state.requests.filter { stamp.seconds(since: $0) < ReloadScheduler.capWindow }
        guard press.requests.count < ReloadScheduler.dailyCap,
              state.lastCapExemption.map({ stamp.seconds(since: $0) >= Self.pressReloadSpacing }) ?? true,
              !conservative || (state.lastRequest.map { stamp.seconds(since: $0) >= ReloadScheduler.conservativeSpacing } ?? true)
        else { return nil }
        // An empty bucket lends one token, so a press that worked redraws.
        guard ReloadBucket.spend(&press, at: stamp, mayBorrow: true) else { return nil }
        let reasons = ReloadScheduler.pressReasons(state, current: current, clock: stamp)
        press.requests.append(stamp)
        press.lastRequest = stamp
        press.lastCapExemption = stamp
        press.requested = current
        press.pending = false
        press.pendingSince = nil
        let id = press.takeRequestId()
        return (press, id, reasons)
    }

    /// Logged when a press falls back to the cached list.
    public static let noFreshLogLine = "press: cswap has no --fresh; measured with the cached list"

    /// The cswap run of a poll. A press's answer re-measures every account
    /// (`--fresh`); a background poll takes cswap's cached list. A cswap
    /// from before `--fresh` refuses the option before doing any work: the
    /// press is then measured with the cached list, once, and the reload
    /// log says so. Any other failure is the press's answer, as for a poll.
    private func runCswap(press: Bool) async -> Result<RunOutput, RunFailure> {
        let result = await runCswap(fresh: press)
        guard press, CswapInterpreter.rejectsFresh(result) else { return result }
        try? CappedLog.append("\(ISODate.format(clock().wall)) \(Self.noFreshLogLine)", to: reloadLogURL,
                              cap: SharedContainer.logCap)
        return await runCswap(fresh: false)
    }

    /// The press a scheduled poll answers in place of measuring the cached
    /// list: one taken and not yet answered, or a new one on disk, taken
    /// under the press rules (`takeRefreshRequest`: a press within
    /// `refreshDebounce` of the last one handled is answered there with the
    /// last snapshot, and the poll stays a background poll). Nil when none.
    private func pressToAnswer() -> RefreshRequest? {
        if takenRequest == nil, !takeRefreshRequest() { return nil }
        defer { takenRequest = nil }
        return takenRequest
    }

    /// One cswap run; a helper left holding its output is counted.
    private func runCswap(fresh: Bool) async -> Result<RunOutput, RunFailure> {
        let result = await runner.runList(fresh: fresh)
        if case .success(let output) = result, output.leftHelper { helperWarnings += 1 }
        return result
    }

    /// A report for an agent that has stopped: no poll, no write.
    private static func stoppedReport(at now: Date) -> TickReport {
        var report = TickReport(writtenAt: now, status: .error, error: nil, reloadReasons: [])
        report.containerChanged = true
        report.error = containerReplacedMessage
        return report
    }

    /// One poll. With `userRequested` (a press), cswap re-measures every
    /// account (`runCswap`), and the reload that follows skips the spacing
    /// (it still counts toward the daily cap). A scheduled poll that finds
    /// a press waiting, before its run or after it, is that press's answer
    /// under the same rules.
    public func tick(userRequested: Bool) async -> TickReport {
        // The container is anchored once at launch. Another folder at its
        // path stops the agent for good: no poll, no write into either
        // folder, nothing migrated. The app logs it and asks for a quit and
        // reopen; the lock on the old folder is simply kept.
        guard containerUsable() else { return Self.stoppedReport(at: clock().wall) }
        // The press this poll answers. It is marked seen once a snapshot
        // answering it is written; if the write fails it is pending again.
        var taken: RefreshRequest?
        if userRequested {
            taken = takenRequest
            takenRequest = nil
        }
        if !loaded {
            // A restart keeps the last good accounts and the scheduler's memory.
            previous = SnapshotStore.read(from: snapshotURL)
            lastWriteSequence = max(WriterStateStore.read(in: directory)?.lastSequence ?? 0, previous?.writeSequence ?? 0)
            if codexCurrent == nil, let seed = Self.lastKnownCodex(in: previous) {
                // The age the snapshot kept on the continuous clock, plus
                // the time since it was written (never less), so a wall
                // clock moved back cannot make old numbers look fresh.
                let now = clock()
                var age: TimeInterval?
                if let kept = previous?.provider(CodexMerge.provider)?.accounts.first?.ageSeconds, let written = previous?.writtenAt {
                    age = kept + max(0, now.wall.timeIntervalSince(written))
                }
                codexCurrent = RememberedReading(seed, at: now, age: age)
            }
            answeredPress = pressAtLaunch ?? previous?.answeredPress
            if case .string(let text)? = previous?.provider(CodexMerge.provider)?.extras[CodexMerge.appServerCheckedAtKey] {
                codexAppServerCheckedAt = ISODate.parse(text)
            }
            loadCodexCalls(previous: previous)
            // Earlier builds left a note here when a press's reload was held.
            SafeFile.remove(directory.appendingPathComponent("refresh-result.json"))
            switch ReloadStateStore.read(from: reloadStateURL) {
            case .loaded(let state):
                reloadState = state
            case .missing:
                break
            case .unreadable(let reason):
                stateError = "Reload state could not be read: \(reason)"
            }
            // A state that reads but cannot be saved (a locked file, say)
            // would let every restart start from the same old memory, so it
            // is saved straight back now; failing that counts like failing
            // to read it.
            if stateError == nil {
                persistState(reloadState)
            }
            if stateError != nil {
                // With no memory to trust, the launch itself counts as a
                // request: restarting cannot buy a reload inside the
                // conservative hour.
                if reloadState.lastRequest.map({ launch.seconds(since: $0) > 0 }) ?? true {
                    reloadState.lastRequest = launch
                }
            }
            loaded = true
        }

        // A scheduled poll with a press waiting (made just before it, or
        // taken and not yet answered) is that press's answer: a fresh run,
        // under a press's rules.
        var answering = userRequested
        if !answering, let pending = pressToAnswer() {
            taken = pending
            answering = true
        }
        var result = await runCswap(press: answering)
        let polled = clock()
        let step = await codexStep(now: polled)
        // A press made while a scheduled poll measured (cswap may take up to
        // 50 s, Codex up to 20 s) is not answered with its cached numbers:
        // the widget's intent takes any newer snapshot for its answer, so
        // they are never written, and the press's fresh run replaces them.
        if !answering, let pending = pressToAnswer() {
            taken = pending
            answering = true
            result = await runCswap(press: true)
        }
        var built = SnapshotBuilder.updating(
            previous,
            provider: CswapListMapper.provider,
            source: CswapListMapper.source,
            outcome: CswapInterpreter.interpret(result),
            now: polled.wall
        )
        // Codex off keeps its last block, hidden, so turning it on again (or
        // restarting) starts from those numbers.
        let keptCodex = built.providers.first { $0.provider == CodexMerge.provider }
        built.providers.removeAll { $0.provider == CodexMerge.provider }
        // A Codex app-server call may have taken up to its 20 s timeout: the
        // snapshot is dated, Codex aged, and the scheduler decides, after it,
        // all at this one reading. The rollout is kept as of when it was
        // read and aged on the continuous clock to here, so a wall clock
        // change meanwhile cannot re-date it.
        let stamp = clock()
        let now = stamp.wall
        if let step {
            built.providers.append(mergeCodex(step.codex, rollout: step.rollout, readAt: polled, now: stamp))
        } else if var kept = keptCodex {
            kept.hidden = true
            built.providers.append(kept)
        }
        built.writtenAt = now
        // A reload state problem is shown where a cswap error would be,
        // without marking the provider as failed.
        if let stateError, let index = built.providers.firstIndex(where: { $0.provider == CswapListMapper.provider }),
           built.providers[index].status == .ok {
            built.providers[index].error = stateError
        }
        let next = SnapshotValidator.sanitized(built)
        let block = next.provider(CswapListMapper.provider)
        var report = TickReport(
            writtenAt: now,
            status: block?.status ?? .error,
            error: block?.error,
            reloadReasons: [],
            writeError: nil
        )
        // Codex's collector state is reported even when the snapshot cannot be written.
        report.codexError = next.provider(CodexMerge.provider)?.collectorError
        if codex != nil {
            report.codexCheckedAt = codexCalls.calls.last?.wall
            report.codexNextCheck = CodexCallPolicy.nextEligible(calls: codexCalls.calls, now: stamp)
            report.codexCallsError = codexCallsError
        }

        // What to ask WidgetKit for is decided before the snapshot is
        // written; nothing is asked for without its snapshot.
        let conservative = stateError != nil
        let current = DisplayFingerprint(next)
        var state = reloadState
        var fire: (id: Int, kind: ReloadLog.Kind, reasons: [ReloadReason], urgent: Bool)?
        // A press's completion reload waits for the snapshot write: until
        // its numbers are on disk nothing about them is saved as requested.
        var pressCandidate: (state: ReloadState, id: Int, reasons: [ReloadReason])?
        if !answering {
            // A press's poll never runs the background decision; whether it
            // needs a completion reload is judged once its answer is written.
            let (decision, decided) = ReloadScheduler.decide(state, current: current, clock: stamp,
                                                             conservative: conservative)
            state = decided
            if decision.fire, let id = decision.id { fire = (id, .background, decision.reasons, decision.urgent) }
        }

        var written = next
        written.writerId = writerId
        // The press this snapshot answers: for a press's poll, the newest
        // press waiting now (one made while it ran is answered too, in the
        // taken press's session) or else the press taken. Any other
        // snapshot carries the last answer forward, so a press still
        // waiting never takes it for its answer.
        var answer: RefreshRequest?
        if answering {
            answer = taken
            if let onDisk = RefreshRequestStore.read(in: directory), isUnseen(onDisk),
               taken.map({ $0.session == onDisk.session && $0.sequence <= onDisk.sequence }) ?? true {
                answer = onDisk
            }
        }
        written.answeredPress = answer.map(AnsweredPress.init) ?? answeredPress
        do {
            let outcome = try SnapshotStore.writeNumbered(written, to: snapshotURL, after: lastWriteSequence)
            lastWriteSequence = outcome.sequence
            written.writeSequence = outcome.sequence
            if let id = outcome.writerId {
                writerId = id
                written.writerId = id
            }
            try? WriterStateStore.write(WriterState(lastSequence: outcome.sequence), in: directory)
            // Another writer numbered past this one: carry on from its
            // number, and say so once.
            if let adopted = outcome.adopted, !loggedAdoption {
                loggedAdoption = true
                try? CappedLog.append("\(ISODate.format(now)) adopted write number \(adopted) from another writer",
                                      to: reloadLogURL, cap: SharedContainer.logCap)
            }
        } catch {
            // Nothing is asked for or saved as requested without its snapshot.
            report.writeError = Redactor.redactEmails((error as NSError).localizedDescription)
            return report
        }
        previous = written
        answeredPress = written.answeredPress
        // Lateness is judged now, with the answer on disk: cswap, Codex and
        // the write all took their time (cswap alone may take up to 50 s).
        // The intent looks for the answer every 0.25 s until its wait ends;
        // a snapshot written within that is seen by its own unbudgeted
        // reload, so only a later one needs the completion reload.
        let answered = clock()
        let tooLate = { (request: RefreshRequest) in
            answered.wall.timeIntervalSince(request.requestedAt) >= RefreshRequestStore.intentWait - RefreshRequestStore.intentPoll
        }
        if answering, taken.map(tooLate) ?? true {
            pressCandidate = completionCandidate(state, current: current, stamp: answered, conservative: conservative)
        }
        // The press this snapshot names is answered, and so marked seen
        // (with any earlier one of its session): taking it again would run
        // cswap once more. If the answer came too late for the intent to see
        // it, and this poll asks for no reload of its own, the completion
        // reload follows. A scheduled poll's cached numbers answer no press:
        // one made after its last look is taken by the loop and measured
        // fresh.
        if let answer, isUnseen(answer) {
            lastSeenRefresh = (answer.session, answer.sequence)
            if fire == nil, pressCandidate == nil, tooLate(answer) {
                pressCandidate = completionCandidate(state, current: current, stamp: answered, conservative: conservative)
            }
        }
        // The completion reload fires only once its time is saved.
        if let pressCandidate {
            if persistState(pressCandidate.state) {
                state = pressCandidate.state
                fire = (pressCandidate.id, .press, pressCandidate.reasons, true)
            }
        }

        reloadState = state
        if state != savedState {
            persistState(state)
        }
        let requests24h = state.requests.filter { stamp.seconds(since: $0) < ReloadScheduler.capWindow }.count
        let bucket = ReloadBucket.status(state, at: stamp)
        report.budget = BudgetStatus(cap: ReloadScheduler.dailyCap, requests24h: requests24h,
                                     nextOrdinary: ReloadScheduler.nextOrdinary(state, clock: stamp,
                                                                                conservative: stateError != nil),
                                     tokens: bucket.available, nextToken: bucket.nextRefill)
        report.stateError = stateError
        report.helperWarnings = helperWarnings
        report.pending = state.pending
        guard let fire else { return report }

        reload()
        report.reloadReasons = fire.reasons
        let line = ReloadLog.line(at: now, reasons: fire.reasons, urgent: fire.urgent, status: report.status.rawValue,
                                  requests24h: requests24h, id: fire.id, kind: fire.kind)
        try? CappedLog.append(line, to: reloadLogURL, cap: SharedContainer.logCap)
        return report
    }
}

/// A reading kept between polls. Its measurement time is never changed;
/// its age at a later poll is the age it had when kept plus the time that
/// really passed on the continuous clock, so setting the wall clock back or
/// forward neither freshens nor ages it. A reading dated ahead of when it
/// was kept counts as taken then.
struct RememberedReading {
    var reading: CodexReading
    var kept: SchedulerClock
    var ageWhenKept: TimeInterval

    /// - Parameter age: the reading's age when kept, when known; otherwise
    ///   it is measured from the wall clock.
    init(_ reading: CodexReading, at stamp: SchedulerClock, age: TimeInterval? = nil) {
        self.reading = reading
        self.kept = stamp
        self.ageWhenKept = age ?? max(0, stamp.wall.timeIntervalSince(reading.measuredAt))
    }

    func reading(at stamp: SchedulerClock) -> CodexReading {
        var copy = reading
        copy.observedAge = stamp.seconds(since: kept) + ageWhenKept
        return copy
    }
}
