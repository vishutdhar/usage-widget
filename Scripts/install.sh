#!/bin/bash
# Installs the Release build to ~/Applications and launches it. The app
# registers itself as a login item on its first launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$ROOT/build/DerivedData/Build/Products/Release/Usage Widget.app"
DEST="$HOME/Applications/Usage Widget.app"
BUNDLE_ID="com.vishutdhar.usagewidget"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$BUILT" ] || { echo "No build found. Run Scripts/build.sh first." >&2; exit 1; }

is_running() {
    [ "$(osascript -e "application id \"$BUNDLE_ID\" is running")" = "true" ]
}

# Quit the running copy by bundle id, and wait for it to exit.
if is_running; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit"
    for _ in $(seq 1 50); do is_running || break; sleep 0.2; done
    if is_running; then echo "Usage Widget did not quit; quit it and run this again." >&2; exit 1; fi
fi

mkdir -p "$HOME/Applications"
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
. "$ROOT/Scripts/kill-extension.sh"
kill_exact_executable "$DEST/$APPEX/Contents/MacOS/UsageWidgetExtension"

open "$DEST"
echo "Installed and launched: $DEST"
