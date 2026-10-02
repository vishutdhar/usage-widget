#!/bin/bash
# Runs install.sh against stub commands and fake app bundles. The old
# installed executable is a build that knows none of today's flags: given
# one it would start the app, so it logs any flag it gets, and the test
# fails if install.sh passes it one. Checks: the job is booted out, a copy
# outside launchd stops (by the new --stop, else by its exact path), the
# app is replaced, the NEW executable registers the job, and the script
# succeeds only when launchd runs the installed file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

make_tmp() {
    local dir
    dir="$(mktemp -d)" || { echo "no temporary folder" >&2; return 1; }
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then echo "no temporary folder" >&2; return 1; fi
    echo "$dir"
}

# A failing mktemp must stop this test before it writes anywhere. The
# failing stub lives in a temporary folder of its own; nothing is made
# outside one.
if [ "${TEST_INSTALL_MKTEMP_CHECK:-}" != 1 ]; then
    CHECK="$(make_tmp)"
    mkdir -p "$CHECK/bin"
    printf '#!/bin/bash\nexit 1\n' > "$CHECK/bin/mktemp"
    chmod +x "$CHECK/bin/mktemp"
    if out="$(TEST_INSTALL_MKTEMP_CHECK=1 PATH="$CHECK/bin:$PATH" "$0" 2>&1)"; then
        rm -rf "$CHECK"
        echo "FAIL (mktemp): the test ran on without a temporary folder"
        exit 1
    fi
    rm -rf "$CHECK"
    case "$out" in
        *"no temporary folder"*) ;;
        *) echo "FAIL (mktemp): unexpected output: $out"; exit 1 ;;
    esac
fi

status=0
fail() { echo "FAIL ($1): $2"; status=1; }

# $1 old copy running outside launchd (1/0), $2 the new --register-job result
# (0 registered, 3 left off, 4 failed), $3 launchd runs the installed file (1/0).
run_case() {
    local TMP
    TMP="$(make_tmp)"
    local STATE="$TMP/state" CALLS="$TMP/calls" BIN="$TMP/bin"
    mkdir -p "$STATE" "$BIN"
    : > "$CALLS"
    echo 1 > "$STATE/registered"
    echo "$2" > "$STATE/register_result"
    echo "$3" > "$STATE/newfile"

    # The new build: a stub that logs its flags and acts on them.
    local new="$TMP/new/Usage Widget.app"
    mkdir -p "$new/Contents/MacOS" "$new/Contents/PlugIns/UsageWidgetExtension.appex/Contents/MacOS"
    cat > "$new/Contents/MacOS/Usage Widget" <<STUB
#!/bin/bash
echo "new \$*" >> "$CALLS"
if [ "\$1" = --register-job ]; then
    result=\$(cat "$STATE/register_result")
    [ "\$result" = 0 ] || exit "\$result"
    echo 1 > "$STATE/registered"
fi
exit 0
STUB
    chmod +x "$new/Contents/MacOS/Usage Widget"

    # The old build: a real program (so it can run at its exact path) that
    # logs any flag it is given and otherwise just runs.
    local DEST="$TMP/home/Applications/Usage Widget.app"
    mkdir -p "$DEST/Contents/MacOS"
    printf '%s\n' '#include <stdio.h>' '#include <stdlib.h>' '#include <unistd.h>' \
        'int main(int argc, char **argv) {' \
        '    const char *log = getenv("STUB_CALLS");' \
        '    if (argc > 1 && log) { FILE *f = fopen(log, "a"); fprintf(f, "old"); for (int i = 1; i < argc; i++) fprintf(f, " %s", argv[i]); fprintf(f, "\n"); fclose(f); }' \
        '    sleep(30); return 0; }' > "$TMP/old.c"
    cc -o "$DEST/Contents/MacOS/Usage Widget" "$TMP/old.c"
    local OLD_PID=""
    if [ "$1" = 1 ]; then
        "$DEST/Contents/MacOS/Usage Widget" & OLD_PID=$!
        sleep 0.3
    fi
    echo "${OLD_PID:-0}" > "$STATE/oldpid"

    cat > "$BIN/osascript" <<STUB
#!/bin/bash
pid=\$(cat "$STATE/oldpid")
if [ "\$pid" != 0 ] && kill -0 "\$pid" 2>/dev/null; then echo true; else echo false; fi
STUB
    cat > "$BIN/launchctl" <<STUB
#!/bin/bash
case "\$1" in
    bootout) echo "launchctl bootout" >> "$CALLS"; echo 0 > "$STATE/registered" ;;
    print) [ "\$(cat "$STATE/registered")" = 1 ] || exit 113; printf '\tstate = running\n\tpid = 4242\n' ;;
    *) echo "launchctl \$1" >> "$CALLS" ;;
esac
STUB
    cat > "$BIN/open" <<STUB
#!/bin/bash
echo "open" >> "$CALLS"
STUB
    cat > "$BIN/lsof" <<STUB
#!/bin/bash
if [ "\$(cat "$STATE/newfile")" = 1 ]; then inode=\$(stat -f %i "$DEST/Contents/MacOS/Usage Widget"); else inode=1; fi
printf 'p4242\nftxt\ni%s\n' "\$inode"
STUB
    printf '#!/bin/bash\nexit 0\n' > "$BIN/pluginkit"
    printf '#!/bin/bash\nexit 0\n' > "$BIN/lsregister"
    chmod +x "$BIN"/*

    CASE_CODE=0
    CASE_OUT="$(STUB_CALLS="$CALLS" PATH="$BIN:$PATH" HOME="$TMP/home" USAGE_WIDGET_BUILT="$new" \
        USAGE_WIDGET_DEST="$DEST" USAGE_WIDGET_LSREGISTER="$BIN/lsregister" USAGE_WIDGET_VERIFY_TRIES=3 \
        USAGE_WIDGET_STOP_TRIES=5 "$ROOT/Scripts/install.sh" 2>&1)" || CASE_CODE=$?
    CASE_CALLS="$(tr '\n' '|' < "$CALLS")"
    CASE_OLD_ALIVE=0
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then CASE_OLD_ALIVE=1; kill "$OLD_PID"; fi
    [ -n "$OLD_PID" ] && wait "$OLD_PID" 2>/dev/null || true
    CASE_NEW_INSTALLED=0
    cmp -s "$new/Contents/MacOS/Usage Widget" "$DEST/Contents/MacOS/Usage Widget" && CASE_NEW_INSTALLED=1
    rm -rf "$TMP"
}

run_case 1 0 1
[ "$CASE_CODE" = 0 ] || fail upgrade "exit $CASE_CODE: $CASE_OUT"
[ "$CASE_CALLS" = "launchctl bootout|new --stop|new --register-job|open|" ] || fail upgrade "sequence $CASE_CALLS"
case "$CASE_CALLS" in *old*) fail upgrade "the old executable was given a flag" ;; esac
[ "$CASE_OLD_ALIVE" = 0 ] || fail upgrade "the old copy outside launchd still runs"
[ "$CASE_NEW_INSTALLED" = 1 ] || fail upgrade "the new copy was not installed"

run_case 0 0 0
[ "$CASE_CODE" != 0 ] || fail stale "succeeded although launchd runs another file"
case "$CASE_OUT" in *"not running the new copy"*) ;; *) fail stale "no message: $CASE_OUT" ;; esac

run_case 0 3 0
[ "$CASE_CODE" = 0 ] || fail off "exit $CASE_CODE: $CASE_OUT"
[ "$CASE_CALLS" = "launchctl bootout|new --register-job|open|" ] || fail off "sequence $CASE_CALLS"
case "$CASE_OUT" in *"without launchd"*) ;; *) fail off "no message: $CASE_OUT" ;; esac

run_case 0 4 0
[ "$CASE_CODE" != 0 ] || fail failed "succeeded although registration failed"
case "$CASE_OUT" in *"registering the launchd job failed"*) ;; *) fail failed "no message: $CASE_OUT" ;; esac
[ "$CASE_CALLS" = "launchctl bootout|new --register-job|" ] || fail failed "sequence $CASE_CALLS"

[ "$status" = 0 ] && echo "install: job booted out, old copy stopped without its flags, replaced, registered by the new copy, verified"
exit "$status"
