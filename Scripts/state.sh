#!/bin/bash
# Prints the installed agent's snapshot and the tails of both refresh logs.
# Usage: Scripts/state.sh [lines]
exec "$HOME/Applications/Usage Widget.app/Contents/MacOS/Usage Widget" --print-state "${1:-20}"
