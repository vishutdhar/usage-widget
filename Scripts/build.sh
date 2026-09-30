#!/bin/bash
# Generates the Xcode project from project.yml, runs the package tests, and
# builds a signed Release app into build/ (the repo's one build folder).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

xcodegen generate --quiet
(cd Packages/UsageKit && swift test)
Scripts/test-kill-extension.sh
xcodebuild \
    -project UsageWidget.xcodeproj \
    -scheme UsageWidget \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    -allowProvisioningUpdates \
    build
echo "Built: $ROOT/build/DerivedData/Build/Products/Release/Usage Widget.app"
