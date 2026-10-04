#!/bin/bash
# Installs the Release build to ~/Applications and opens it. Opening
# registers the app's launchd job (start at login, restart after a crash)
# and hands the agent to it. Scripts/test-install.sh runs this with stubs;
# the USAGE_WIDGET_* variables are for that test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="${USAGE_WIDGET_BUILT:-$ROOT/build/DerivedData/Build/Products/Release/Usage Widget.app}"
DEST="${USAGE_WIDGET_DEST:-$HOME/Applications/Usage Widget.app}"
LSREGISTER="${USAGE_WIDGET_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
VERIFY_TRIES="${USAGE_WIDGET_VERIFY_TRIES:-40}"
STOP_TRIES="${USAGE_WIDGET_STOP_TRIES:-50}"
OPEN_TRIES=5
OPEN_WAIT="${USAGE_WIDGET_OPEN_WAIT:-1}"
BUNDLE_ID="com.vishutdhar.usagewidget"
EXE="Contents/MacOS/Usage Widget"
JOB="gui/$(id -u)/com.vishutdhar.usagewidget.agent"

[ -d "$BUILT" ] || { echo "No build found. Run Scripts/build.sh first." >&2; exit 1; }

is_running() {
    [ "$(osascript -e "application id \"$BUNDLE_ID\" is running")" = "true" ]
}

wait_until_stopped() {
    for _ in $(seq 1 "$STOP_TRIES"); do is_running || return 0; sleep 0.2; done
    return 1
}

# Only mechanisms every earlier build supports, since the old executable
# may know none of today's flags (running it with one would start it).
# The job first: bootout stops launchd's copy and keeps KeepAlive from
# starting it again ("not found" when there is no job is fine).
launchctl bootout "$JOB" >/dev/null 2>&1 || true
# Then a copy outside launchd: the new executable's --stop reaches builds
# that have Stop; any other ends by its exact executable path.
. "$ROOT/Scripts/kill-extension.sh"
if is_running; then
    "$BUILT/$EXE" --stop
    if ! wait_until_stopped; then
        kill_exact_executable "$DEST/$EXE"
        wait_until_stopped || { echo "Usage Widget did not stop; stop it and run this again." >&2; exit 1; }
    fi
fi

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

# Point LaunchServices (and so the widget system) at the installed copy
# only, not at the copy in build/.
APPEX="Contents/PlugIns/UsageWidgetExtension.appex"
for CONFIG in Debug Release; do
    COPY="$ROOT/build/DerivedData/Build/Products/$CONFIG/Usage Widget.app"
    [ -d "$COPY" ] || continue
    pluginkit -r "$COPY/$APPEX" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$COPY" >/dev/null 2>&1 || true
done
"$LSREGISTER" -f "$DEST"
pluginkit -a "$DEST/$APPEX"

# A widget extension already running keeps the old code until it exits;
# end that process (matched by its exact installed executable path, as a
# plain string) so WidgetKit starts the new one on the next reload.
kill_exact_executable "$DEST/$APPEX/Contents/MacOS/UsageWidgetExtension"

# A replaced app's job must be registered again: the new executable does
# it, keeping the person's Start at login choice (exit 3 when left off or
# awaiting approval, 4 when registration failed). Opening then shows the
# status window (launchd's copy, or this copy when the job cannot run).
REGISTERED=true
REGISTER_STATUS=0
"$DEST/$EXE" --register-job || REGISTER_STATUS=$?
case "$REGISTER_STATUS" in
    0) ;;
    3) REGISTERED=false ;;
    *) echo "Installed, but registering the launchd job failed (status $REGISTER_STATUS); see above." >&2
       exit 1 ;;
esac
# The window is a courtesy; launchd running the new copy (checked below)
# decides the result. Right after the job registers, LaunchServices can
# refuse the open (error -600: the copy launchd just started is not known
# to it yet), so it is tried a few times, then only noted.
OPENED=false
for try in $(seq 1 "$OPEN_TRIES"); do
    if open "$DEST"; then OPENED=true; break; fi
    if [ "$try" -lt "$OPEN_TRIES" ]; then sleep "$OPEN_WAIT"; fi
done
if [ "$OPENED" = false ]; then
    if [ "$REGISTERED" = false ]; then
        # With Start at login off, the opened copy is the one that runs.
        echo "Installed, but Usage Widget could not be opened and Start at login is off or awaits approval, so nothing runs it; open it by hand." >&2
        exit 1
    fi
    echo "The status window could not be opened; checking that launchd runs the new copy anyway." >&2
fi

# launchd must now run the installed executable: the job's process has
# that very file (same device and inode) open as its program text.
# An inode number is unique on its device only, so both are compared (lsof
# gives the device in hex).
job_runs_installed_copy() {
    local pid want line dev=""
    pid="$(launchctl print "$JOB" 2>/dev/null | awk '/^\tpid = /{print $3}')"
    [ -n "$pid" ] || return 1
    want="$(stat -f '%d:%i' "$DEST/$EXE")"
    while IFS= read -r line; do
        case "$line" in
            D*) dev=$(( ${line#D} )) ;;
            i*) [ "$dev:${line#i}" = "$want" ] && return 0 ;;
        esac
    done < <(lsof -a -p "$pid" -d txt -FDi 2>/dev/null)
    return 1
}
for _ in $(seq 1 "$VERIFY_TRIES"); do
    if job_runs_installed_copy; then
        echo "Installed; launchd runs it: $DEST"
        exit 0
    fi
    sleep 0.5
done
if [ "$REGISTERED" = true ]; then
    if [ "$OPENED" = true ]; then
        echo "Installed, but launchd is not running the new copy; see its status window." >&2
    else
        echo "Installed, but launchd is not running the new copy; open Usage Widget by hand to see its status window." >&2
    fi
    exit 1
fi
echo "Installed and opened without launchd (Start at login is off or awaits approval): $DEST"
