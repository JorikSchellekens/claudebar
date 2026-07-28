#!/usr/bin/env bash
# Build ClaudeBar, install it to ~/Applications, and register a LaunchAgent so
# it starts at login and gets restarted if it ever dies.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HOME/Applications/ClaudeBar.app"
LABEL="com.jorikschellekens.claudebar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> building"
cd "$REPO"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeBar"

echo "==> installing to $APP"
# Stop the running copy first; you cannot overwrite a running binary in place.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
pkill -x ClaudeBar 2>/dev/null || true
sleep 1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeBar"
cp "$REPO/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature. Rebuilding changes the code hash, so macOS will ask for
# keychain access again after each reinstall - click "Always Allow".
codesign --force --sign - --identifier "$LABEL" "$APP"

echo "==> writing $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/ClaudeBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/claudebar.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claudebar.err</string>
</dict>
</plist>
PLISTEOF

echo "==> loading"
launchctl bootstrap "gui/$UID" "$PLIST"

echo
echo "done. ClaudeBar is running at the bottom of your screen and will"
echo "start automatically at login."
echo "  logs:      /tmp/claudebar.log /tmp/claudebar.err"
echo "  uninstall: ./uninstall.sh"
