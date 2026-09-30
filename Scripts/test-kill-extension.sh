#!/bin/bash
# Checks kill_exact_executable: the exact path dies, a decoy whose path has
# an X where the real one has a dot survives.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Scripts/kill-extension.sh"
TMP="$(mktemp -d)"
REAL="$TMP/Usage Widget.app/Contents/PlugIns/UsageWidgetExtension.appex/Contents/MacOS/UsageWidgetExtension"
DECOY="$TMP/Usage Widget.app/Contents/PlugIns/UsageWidgetExtensionXappex/Contents/MacOS/UsageWidgetExtension"
mkdir -p "$(dirname "$REAL")" "$(dirname "$DECOY")"
# A copied system binary is refused outside its own path, so build a
# tiny sleeper (ad-hoc signed by the linker) and put it at both paths.
printf '#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n' > "$TMP/sleeper.c"
cc -o "$TMP/sleeper" "$TMP/sleeper.c"
cp "$TMP/sleeper" "$REAL"; cp "$TMP/sleeper" "$DECOY"
"$REAL" & REAL_PID=$!
"$DECOY" & DECOY_PID=$!
sleep 0.5
kill_exact_executable "$REAL"
sleep 0.5
status=0
if kill -0 "$REAL_PID" 2>/dev/null; then echo "FAIL: the exact path is still running"; status=1; fi
if ! kill -0 "$DECOY_PID" 2>/dev/null; then echo "FAIL: the decoy was killed"; status=1; fi
kill "$REAL_PID" "$DECOY_PID" 2>/dev/null; wait 2>/dev/null
rm -rf "$TMP"
[ "$status" = 0 ] && echo "kill-extension: exact path ended, decoy left running"
exit "$status"
