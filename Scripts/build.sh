#!/bin/bash
# Generates the Xcode project from project.yml, runs the package tests, and
# builds a signed Release app into build/ (the repo's one build folder).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate --quiet
(cd Packages/UsageKit && swift test)
Scripts/test-kill-extension.sh
Scripts/test-install.sh
xcodebuild \
    -project UsageWidget.xcodeproj \
    -scheme UsageWidget \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    -allowProvisioningUpdates \
    build
APP="$ROOT/build/DerivedData/Build/Products/Release/Usage Widget.app"
# The launchd job must ship inside the app, where SMAppService.agent looks.
plutil -lint "$APP/Contents/Library/LaunchAgents/com.vishutdhar.usagewidget.agent.plist" >/dev/null
cmp -s "$ROOT/LaunchAgent/com.vishutdhar.usagewidget.agent.plist" \
    "$APP/Contents/Library/LaunchAgents/com.vishutdhar.usagewidget.agent.plist" \
    || { echo "The app's launchd job differs from LaunchAgent/." >&2; exit 1; }
echo "Built: $APP"
