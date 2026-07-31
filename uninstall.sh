#!/usr/bin/env bash
set -euo pipefail

LABEL="com.jorikschellekens.claudebar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -x ClaudeBar 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$HOME/Applications/ClaudeBar.app"
rm -rf "$HOME/.config/claudebar"
defaults delete "$LABEL" 2>/dev/null || true
# Older versions kept a token of their own in the keychain.
security delete-generic-password -s "$LABEL" >/dev/null 2>&1 || true

echo "ClaudeBar removed."
