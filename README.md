# Usage Widget

A macOS desktop widget that shows your Claude Code and Codex subscription
usage at a glance, for all your accounts.

## Install

Requirements:

- macOS 15 or later
- Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`)
- cswap (the `claude-swap` command line tool) installed and signed in to
  your accounts; the widget reads `cswap list --json`
- the Codex CLI, optional: when `~/.codex` exists the widget shows Codex too

The app and the widget share an App Group whose id starts with an Apple
team id, so both must be signed with your own team. Replace `DABJS94K9F`
with your team id in `project.yml` (`DEVELOPMENT_TEAM` and the two App
Group entries), in `App/UsageWidget.entitlements`,
`Widget/UsageWidgetExtension.entitlements`, and in
`Packages/UsageKit/Sources/UsageCore/SharedContainer.swift`. Then:

```
git clone <this repository>
cd usage-widget
Scripts/build.sh     # generates the project, runs the tests, builds Release
Scripts/install.sh   # installs to ~/Applications and launches it
```

Then add the widget: right-click the desktop, choose Edit Widgets, search
"Usage", and drag it onto the desktop.

## What it does

A macOS desktop widget that shows per-account usage limits, fed by
`cswap list --json`, and Codex usage from Codex's own session files and
the Codex CLI's `app-server`. cswap and the Codex CLI fetch usage from their
providers; the agent and the widget make no network calls of their own.

## How it fits together

```
cswap list --json  ->  Usage Widget.app (agent)  ->  snapshot.json  ->  widget extension
   every 60 s           unsandboxed, launchd job     App Group            sandboxed, reads only
Codex rollouts, every 60 s   ^
codex app-server, at most 8 a day
```

- **Agent app** (`com.vishutdhar.usagewidget`): no Dock icon. Every minute it
  runs cswap (`~/.local/bin`, then `/opt/homebrew/bin`, then `/usr/local/bin`)
  in its own process group with a 50 s timeout and capped output, maps the
  result into the snapshot schema, validates it, and writes `snapshot.json`
  atomically (temporary file, then rename). When cswap is missing or fails,
  the snapshot says `"status": "error"` with a short reason and keeps the
  last good accounts with their `fetchedAt`. One agent runs at a time: it
  holds `agent.lock`, and a second copy hands over to the running one and
  quits. Opening the app while it runs shows a small status window (last
  update, last error, Show Codex, Start at login).
- **Codex** (on by default when `~/.codex` exists; the status window's Show
  Codex toggle turns it off and on; off stops polling and keeps the block
  in the snapshot marked `hidden`, which the widget, the reload fingerprint
  and the timeline treat as absent, so turning it on again, or restarting,
  starts from those numbers; on asks the app-server only if the day's
  ceiling allows):
  - every poll the agent reads the five most recently modified
    `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` files of the last seven
    day folders, at most the last 512 KB of each (the size taken once, at
    open), and keeps the reading with the newest event time. No network.
    Only regular, single-link files whose folder resolves inside
    `~/.codex/sessions` are read; they are opened without following links
    and checked to be the file discovery found. Symlinks, FIFOs, folders,
    hard links, anything named `auth.json` and anything directly in
    `~/.codex` are refused before any open.
  - an event dated more than two minutes ahead is invalid and skipped like
    an empty one (noted once per file in the debug log); its file may still
    give an earlier event. Real rollouts are never dated ahead, and during
    clock skew the app-server and the last good reading cover.
  - the reading shown is kept between polls and never re-dated; it ages by
    the continuous clock. A live app-server answer always replaces it; a
    rollout event only when its own time is strictly newer, so after the
    clock is set back an older event cannot take its place.
  - it runs `codex app-server` over stdio once at start; then only when
    Codex is idle (no rollout reading within the last hour) and three hours
    have passed since the last call; and every six hours for the banked
    reset count. Never more than eight calls in any 24 hours: the call
    times are kept in `codex-calls.json` beside the reload state, so a
    restart cannot reset the count. Every call is written to the log before
    it is made, and a call whose record cannot be written does not happen.
    A log that is corrupt or from another version counts as a full day
    (eight calls at launch); with no log, a snapshot's codex block counts
    as a full day from when the app-server last answered. If the log cannot be written
    at launch, the launch itself counts as a call. The status window shows when
    Codex was last checked and the earliest next check. Each call runs in
    its own process group (20 s timeout, capped output): the `initialize`
    handshake, the `initialized` notification, one
    `account/rateLimits/read`, then stdin closes and the child is reaped.
    Every line sent is built through a method allowlist that throws on
    anything else, so the reset-credit consume method cannot be sent. The
    agent never reads `~/.codex/auth.json` or any token.
  - windows are classified by length, never by position: up to six hours is
    a session named from its length ("5h"), a day or more is "Weekly". The
    windows shown come from whichever reading was measured last; the banked
    reset count comes only from the app-server.
  - a failed app-server call is not a change in usage: while any reading is
    under four hours old the block stays `ok` and the reason goes to
    `collectorError`, which the status window shows and the widget does not.
    Without a fresh reading the account is `stale` ("No new reading") and a
    failing call becomes the block's `error`. With neither a binary nor
    session files it is `unavailable` ("Codex not found").
  - a restart starts from the codex block already in the snapshot
    (windows, plan, reset count, measurement time), so going offline does
    not blank it; the usual staleness rules then apply.
- **Reload scheduling**: WidgetKit allows roughly 40 to 70 reloads a day, so
  writing the snapshot and asking for a reload are separate. The scheduler
  compares each poll with what the widget was last asked to show:
  - urgent changes (status, active account, an account or window appearing or
    disappearing, crossing 70, 90 or 100, a reset moving more than 5 minutes
    inside the next day) are requested once 10 minutes have passed since the
    last request;
  - ordinary changes (percent, a pace tick appearing, a far reset moving, a
    provider's plan or banked reset count, a provider's error line) also
    wait 10 minutes;
  - the shown numbers about to pass their provider's stale line (two
    hours for Claude, four for Codex) while newer ones exist is an ordinary
    change;
  - every request takes a token from a bucket that holds at most 6 and
    gains one every 36 minutes (40 a day); with none, the change waits for
    the next token. A busy afternoon spends the saved tokens and then one
    every 36 minutes, so the night still gets reloads (a fixed 40 in 24
    hours used to run out by evening and leave the widget hours behind
    overnight). A press's reload takes no token and is not counted here
    (see Refresh button). At most 47 in any 24 hours, a ceiling kept as a
    backstop; with the widget's own 3 hour fallback (8 a day) the worst
    background day is 55.
    The status window shows the tokens and when the next one arrives.

  Ages use the continuous clock within a boot, so wall clock changes neither
  erase nor invent time. Its memory lives in `reload-state.json`, so a
  restart forgets nothing; if that file cannot be saved the agent allows
  one request an hour and says so in the status window.
- **Refresh button**: a circular arrow at the right of both sizes' footer.
  Its intent only writes `refresh-request.json` into the group container
  and returns at once (the extension never runs a process and never waits
  for the agent). WidgetKit reloads the widget as the intent returns, a
  reload that is not budgeted, and that reload already says
  "Refreshing…", so a press redraws once instead of dimming, showing the
  old numbers again and redrawing a third time. The agent looks for a
  press every half second and answers with an immediate
  `cswap list --json --fresh` and a new snapshot. `--fresh` makes cswap
  re-measure every account now (it serves as they are only the accounts it
  is holding back: quarantined, backing off after a 429, or claimed),
  where a background poll's `cswap list --json` serves an account's cached
  numbers while they are younger than cswap's serve time (3 to 10
  minutes). Once that snapshot is written the agent asks WidgetKit for one
  reload, which shows the fresh numbers and an "as of" at the time of the
  press (the line keeps its rule, the oldest measurement on screen), so
  the footer says "Refreshing…" for the one to three seconds the
  measurement takes. A press made just before or during a scheduled poll
  makes that poll its answer, under a press's rules: the poll runs
  `--fresh`, and cached numbers it already measured are not written. A
  press is answered only by a snapshot that names it (`answeredPress`,
  below), so a background poll's snapshot written meanwhile, newer but
  naming no new press, does not end "Refreshing…". A cswap from before
  `--fresh` refuses the option before doing any work (argparse's exit
  status 2 and "error: unrecognized arguments: --fresh" on stderr): the
  agent then measures the press once more with the cached
  `cswap list --json` and writes one line, "press: cswap has no --fresh;
  measured with the cached list", to `reload-log.txt`. Any other failure
  is shown as it is for a background poll.

  Every answered press gets its reload, logged as `kind=press`: a press
  costs one reload request. It is never held by the 10 minute spacing,
  the daily ceiling or the conservative hour, since a press is the
  person's own and the 30 second debounce bounds it (WidgetKit keeps its
  own limits). It takes no token from the bucket and is not counted
  against the ceiling, so presses never cost the background its reloads;
  like any request it starts the 10 minute spacing and records what the
  widget now shows. A press never runs the background scheduler. Presses
  are numbered by the intent under a random session id (a new session
  when the file is deleted or damaged), so a clock set back does not stop
  them. A press within 30 seconds of the last one handled runs no second
  measurement: the agent answers it at once with the last snapshot, and
  with its own reload. A press the agent never answers gets no reload,
  and after 90 seconds the footer goes back to the last measured time; a
  press never shows anything about limits.
  `"Usage Widget" --request-refresh` presses it from a terminal.
- **Widget extension** (`com.vishutdhar.usagewidget.widget`): medium (the
  active account, at most three rows, then Codex on one line, then the other
  accounts one line each) and large (every account in full with Codex below,
  its plan beside the name and "2 resets available" on the right; when it
  does not fit, the spacing tightens, then the stale lines move into the
  headers ("stale 5:30 AM" where "active" sits), then accounts are cut to
  three rows and then two (the weekly window and the busiest model), and
  only then are Claude accounts left out from the end, never the active
  one; as a last resort Codex is drawn on one line; it is never left out,
  in either size).
  It only
  reads the snapshot; it never runs a process. It says "as of" the oldest
  current Claude measurement on screen that is not stale ("as of 7:08 PM
  yesterday" for the day before), so the footer never claims a time newer
  than a number it speaks for; stale accounts carry their own line (with
  only stale ones shown, their oldest time). A Codex reading older than
  that (Codex is asked at most eight times a day) says "as of" its own
  time on its own line rather than dragging the footer back; with no
  Claude numbers on screen the footer speaks for the others, and with none
  at all it gives when the snapshot was written. It marks an account whose numbers are over two hours old with
  "stale · as of" their time under its name while its bars keep their
  colours, and shows a failing account's note with when its numbers were
  last known. A snapshot more than 5 minutes old when the widget reads it
  means the agent is not running (it writes every minute), and the footer
  says "Not updating; open Usage Widget". Its timeline has an entry at the
  end of each 5 minute bucket holding a reset or a stale crossing, at most
  eight, and asks for a fresh timeline after 3 hours.
- **App Group**: `<team id>.com.vishutdhar.usagewidget`, at
  `~/Library/Group Containers/<team id>.com.vishutdhar.usagewidget/`.

Shared code lives in the `Packages/UsageKit` package:

| Target | Linked by | Holds |
| --- | --- | --- |
| `UsageCore` | app and widget | snapshot schema, cswap mapping, validation, thresholds, display rows, change detection, reload scheduler, timeline plan, atomic file, capped log, instance lock, redactor |
| `UsageAgentCore` | app only | cswap locator and runner, interpreter, Codex rollout reader, app-server client and method allowlist, login item manager, the per-minute tick |
| `UsageWidgetUI` | widget (and render tests) | the SwiftUI widget views |

## Snapshot schema (version 1)

```json
{
  "schemaVersion": 1,
  "writtenAt": "2026-01-15T10:01:00.000Z",
  "writeSequence": 1000,
  "answeredPress": {"session": "6F1C0A52-…", "sequence": 12},
  "providers": [{
    "provider": "claude", "source": "cswap-list", "status": "ok", "error": null,
    "accounts": [{
      "id": "1", "label": "you@example.com", "active": true,
      "fetchedAt": "2026-01-15T10:00:00.000Z",
      "status": "ok", "statusNote": null, "ageSeconds": null,
      "windows": [{
        "kind": "weekly", "name": "7d", "windowSeconds": 604800, "usedPct": 80,
        "resetsAt": "2026-01-16T19:00:00.000Z", "expectedPct": 70, "aheadOfPace": false,
        "amount": null, "limit": null, "currency": null
      }]
    }],
    "extras": {}
  }]
}
```

- `kind` is `session`, `weekly`, `model` or `spend`. Time windows are
  classified by length (under a day is a session); spend carries `amount`,
  `limit` and `currency`.
- `usedPct` is null when cswap gave no usable number (missing, not a number,
  infinite, or above 10,000); the widget shows "?" with no bar.
- An account's `status` is `ok`, `relogin_required`, `unavailable` or
  `stale` (last known numbers, measured at `fetchedAt`), with a short
  `statusNote`. Freshness is per account: the widget marks an account stale
  once its own `fetchedAt` is past its provider's line at the entry's date:
  two hours for Claude (cswap refreshes every few minutes) and four for
  Codex (asked every three hours while idle), so Codex does not flip stale
  and back between answers. A medium widget's one-line account keeps its
  percentages; when they are not current it adds "as of" their time.
  `ageSeconds` is set on the Codex account: how old its numbers were when
  the snapshot was written, on the agent's continuous clock. The widget
  ages Codex numbers from it (plus the time since the write), so a wall
  clock change neither marks fresh numbers stale nor old ones fresh. A rollout event or app-server
  reply without a usable window is not a reading.
- `writeSequence` goes up by one with every write, and `writerId` is a
  random id the agent draws at each launch. They, not `writtenAt` (which
  is for display), decide order: the agent keeps its last number in
  `writer-state.json`, adopts a higher number found on disk (logged once)
  rather than stopping, and treats a number outside 0 to Int.max/2 as a
  corrupt snapshot. Neither decides whether a refresh press is answered.
- `answeredPress` names the newest refresh press answered (its session and
  number): a press's poll names the press it measured for (and a press
  made while it ran), and every other write carries the last one forward.
  A press is answered by a snapshot naming it or a later press of its
  session, never merely by a newer snapshot, so a clock correction, a
  deleted snapshot, a restart or a wrap of the numbers cannot fake an
  answer. A press on disk when the agent starts, still inside its 90 s
  window and named by no snapshot (the agent restarted between the press
  and its answer), is answered fresh with its reload, so a restart does
  not strand it either; any other counts as old, and the restarted agent's
  first snapshot names it. Absent before the first press.
- Every file in the group container (the snapshot, refresh request,
  reload and writer state, Codex call log, both logs and the lock)
  and every Codex rollout is read and written through one helper. The
  container folder is anchored once per process as a directory
  descriptor (a real folder, not a link, the same inode lstat saw); every
  container file is then reached with openat, fstatat, renameat and
  unlinkat on that descriptor and a single-component name, so swapping
  another folder in at the path later cannot redirect anything. Only a
  regular file with a single link is used, opened without following links
  and checked to be the file it looked at; writes create a new file and
  rename it over the old one, so a link is replaced, never written
  through. Logs never wait on a held lock: after 250 ms the line is
  skipped. Snapshot and press numbers stay below Int.max/2 and wrap to 1
  under a new writer id or session. A test fails if
  any other file access appears in the package, the app or the widget.
- Optional values are explicit `null`. The `codex` provider is another entry
  in `providers`, with `source` `rollout` or `app-server`, one account
  (`id` `codex`, label `Codex`), `extras`
  `{"resetCreditsAvailable": 2, "planType": "pro", "appServerCheckedAt": "..."}`
  (any may be null; the last is when the app-server last answered, which a
  restart uses to seed its daily ceiling),
  `collectorError` (null unless an app-server call is failing), and
  `hidden` (true while Show Codex is off; every block carries it).

## Build, install, add the widget

```
Scripts/build.sh     # xcodegen, package tests, signed Release build into build/
Scripts/install.sh   # copies to ~/Applications, registers, launches
```

The agent runs as a launchd job (`LaunchAgent/`, copied into the app and
registered with SMAppService). launchd starts it at login and starts it
again after any exit but a clean one. Only Stop in the status window,
confirmed in its sheet, and the end of the session (log out, restart, shut
down) exit 0; any other quit, such as a quit Apple Event or a stray
automated click, exits 1 and the agent comes back. After Stop it stays
stopped until the next login or until the app is opened; while it is
stopped the widget says "Not updating". Turning Start at login off removes
the job and so stops the agent at once; turning it on starts it. Each
launch reads the job's status and registers it when it is not registered,
unless Start at login was turned off in the status window. The running
copy is always launchd's: a copy opened by hand registers the job if it
should, starts it, and leaves only once another live process holds the
agent lock (its holder writes its pid into the lock file), then asks that
copy for its window. launchd's copy waits up to 10 s for the lock while
another copy is leaving, and exits non-zero if it never gets it, so
KeepAlive tries again. When the job cannot run (Start at login off,
awaiting approval, a registration error, a failed kickstart, or no
takeover within 15 s) the opened copy runs the agent itself, and its
status window says it is not supervised and why; it tries again every
minute, pausing its polling and letting go of the lock only after
kickstart worked, and takes the lock back if nobody took it. An old app login
item turned off in System Settings carries over as Start at login off.
From a terminal, the app's executable takes `--stop` (as Stop does),
`--start-at-login on|off` (as the toggle does) and `--register-job`.
`Scripts/install.sh` stops the agent with means every earlier build
supports (`launchctl bootout` for the job, the new `--stop` for a copy
outside launchd, else ending it by its exact path), replaces the app, has
the new executable register the job again (a replaced app must be), opens
it, and checks that launchd's process runs the installed executable;
`Scripts/test-install.sh` checks that sequence with stubs, including an
old executable that knows none of the flags.
Builds before this registered the app itself as a login item; the first
launch removes that item once and registers the job in its place. Placing a widget has no public API, so
this step is manual: right-click the desktop, choose Edit Widgets, search
"Usage", and drag the medium size onto the desktop.

## Reading the state and the refresh logs

macOS keeps other processes out of an app's group container, so read it
through the agent binary, which carries the group entitlement:

```
Scripts/state.sh 50   # snapshot, reload state, Codex call log, last 50 lines of each log
```

- `reload-log.txt`: one line per reload the agent requested, with its
  reasons, whether it was urgent, the background requests in the last day,
  its number (`id=`) and its kind: `background` (a change worth showing) or
  `press` (the reload for an answered press). Only background ones count
  toward the 40.
- `timeline-log.txt`: one line per `getTimeline` call the widget received,
  with the widget family, the write number of the snapshot it loaded
  (`snapshot=`), that snapshot's time and age, the entry count, and when it
  asked to reload (`reloadAfter=`).

Both keep their newest 2,000 lines. To see how often macOS honours the
agent's requests, read them side by side by hand: a `reload` line followed
within a few seconds by a `getTimeline` line was most likely honoured. Some
calls have other causes, which the logs do not tell apart: the reload as a
press's intent returns (a `refresh-request.json` just before it, with no
`reload` line), the widget's own fallback (at an earlier line's
`reloadAfter`), and system refreshes. A press shows as that first call,
then a `press` line and the call after it, which brings the fresh numbers. Nothing in the app measures or adapts to this; the cap is fixed.

## Limitations

- **Helpers that escape the process group.** cswap runs in its own process
  group, and a timeout signals the whole group. A descendant that starts a
  new session (setsid) leaves the group, and macOS has no job object to
  track it. cswap does not start such helpers today. If one ever holds
  cswap's output after cswap exits, the agent waits 2 seconds, kills the
  group, moves on, logs "cswap left a helper holding its output", and counts
  it in the status window.
- **Codex freshness.** Rollout files only change while Codex runs, so
  between sessions the Codex numbers come from the app-server calls made
  while Codex is idle, at most every three hours.
- **Codex CLI leftovers.** Each `codex app-server` launch leaves an empty
  temporary git folder in `~/.codex/.tmp` (the CLI's own behaviour; it
  creates no session or rollout files and leaves `auth.json` alone). With
  at most eight launches a day, that is at most eight small folders,
  usually one to four. The agent never deletes anything in `~/.codex`.
- **Refresh budget.** WidgetKit decides when a widget actually reloads. The
  agent asks at most 40 times a day for background changes and the
  widget's own timeline at most 8, so a change can take 10 minutes to
  appear, longer once the 40 are spent or if macOS is stricter. On top of
  those, a press costs one reload request: the agent's reload once the
  press's fresh answer is written (`cswap list --json --fresh`; with a
  cswap from before that option, the cached list). The reload as the
  intent returns is not budgeted. Presses take nothing from the 40, and
  macOS may still hold a reload once its own budget is spent; the "as of"
  line always says when the numbers on screen were measured.

## Tests

```
cd Packages/UsageKit && swift test
```

Render tests draw every state at real widget sizes in light and dark and
compare each with an approved image in `Tests/UsageWidgetUITests/Approved/`.
They save their PNGs to a temporary folder, so a plain `swift test` leaves
the repository alone; `RENDER_DIR` picks the folder. After an intended
visual change, look at the new PNGs, then approve them, which also refreshes
the repository's `renders/`:

```
RENDER_DIR=/tmp/usage-renders swift test --filter RenderTests   # to look
APPROVE_RENDERS=1 swift test --filter RenderTests                # to approve
```

Approved images follow the fonts of the Mac that approved them, so another
macOS version may need a fresh approval.

---

A Freedom Terminal product · support@freedom-terminal.com
