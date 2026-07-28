#!/usr/bin/env bash
# Give ClaudeBar its own long-lived token so it never has to touch Claude Code's
# keychain item (which rotates hourly, resetting its ACL and re-prompting).
#
#   1. claude setup-token      # prints a long-lived token
#   2. ./set-token.sh          # paste it here
set -euo pipefail

SERVICE="com.jorikschellekens.claudebar"
APP="$HOME/Applications/ClaudeBar.app"
BIN="$APP/Contents/MacOS/ClaudeBar"
LABEL="$SERVICE"

if [ ! -x "$BIN" ]; then
    echo "ClaudeBar is not installed yet. Run ./install.sh first." >&2
    exit 1
fi

if [ $# -ge 1 ]; then
    TOKEN="$1"
else
    echo "Run 'claude setup-token' in another terminal, then paste the token here."
    read -r -s -p "token: " TOKEN
    echo
fi

TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"
if [ -z "$TOKEN" ]; then
    echo "no token given" >&2
    exit 1
fi

echo "==> checking the token against the usage endpoint"
CODE="$(curl -s -o /dev/null -w '%{http_code}' \
    https://api.anthropic.com/api/oauth/usage \
    -H "Authorization: Bearer $TOKEN" \
    -H "anthropic-beta: oauth-2025-04-20")"

if [ "$CODE" != "200" ]; then
    echo "the usage endpoint rejected that token (HTTP $CODE); nothing was stored." >&2
    exit 1
fi
echo "    ok"

echo "==> storing it in the keychain, trusted by ClaudeBar only"
# Recreate rather than update: -U keeps the old ACL, and the point here is the ACL.
security delete-generic-password -s "$SERVICE" >/dev/null 2>&1 || true
security add-generic-password \
    -s "$SERVICE" \
    -a token \
    -l "ClaudeBar token" \
    -D "application password" \
    -T "$BIN" \
    -w "$TOKEN"

echo "==> restarting ClaudeBar"
launchctl kickstart -k "gui/$UID/$LABEL" >/dev/null 2>&1 || true

echo
echo "done. ClaudeBar now uses its own token and will not prompt for keychain"
echo "access again. Re-run this if you ever revoke or rotate that token."
