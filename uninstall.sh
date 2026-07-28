#!/usr/bin/env bash
set -euo pipefail

LABEL="com.jorikschellekens.claudebar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -x ClaudeBar 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/ClaudeBar.app"
defaults delete "$LABEL" 2>/dev/null || true

echo "ClaudeBar removed."
