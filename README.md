# ClaudeBar

A small always-on-top bar pinned to the bottom of the macOS screen showing how
much Claude usage you have left.

```
  claude   5h ▰▰▰▰▱ 83% 23m   Week ▰▰▰▱▱ 68% 1d 21h   Fable ▰▰▰▰▱ 77% 1d 21h
```

Each meter is **remaining** percentage plus the countdown to when that window
resets. Green above 30% left, amber below, red below 10%.

## What it reads

It calls `https://api.anthropic.com/api/oauth/usage` - the same endpoint
Claude Code's `/usage` command uses - and renders the `limits` array it returns
(the session window, the weekly all-model window, and any per-model weekly
window). Auth is the OAuth token Claude Code already stores in your login
keychain under the service `Claude Code-credentials`, falling back to
`~/.claude/.credentials.json`.

ClaudeBar never refreshes or rewrites that token; rotating it would pull it out
from under Claude Code. If it expires, ClaudeBar shows `re-auth needed` and
picks up the new token once Claude Code refreshes it.

Polls once a minute, and again on wake from sleep.

## Install

```sh
./install.sh
```

That builds a release binary, packages `~/Applications/ClaudeBar.app`, and
installs a LaunchAgent (`com.jorikschellekens.claudebar`) with `RunAtLoad` and
`KeepAlive`, so it starts at login and restarts if it ever dies.

On first launch macOS asks for permission to read the Claude Code keychain
item - choose **Always Allow**. The app is ad-hoc signed, so its code hash
changes whenever you rebuild, and macOS will ask again after a reinstall.

## Using it

- **Drag** the pill anywhere; the position is remembered.
- **Click** it to refresh immediately.
- **Right-click** for Refresh / Reset position / Quit.

It lives on every space and floats over full-screen apps. It sits above the
Dock by default (it is positioned in the screen's visible frame).

## Uninstall

```sh
./uninstall.sh
```

## Logs

```
/tmp/claudebar.log
/tmp/claudebar.err
```

## Layout

| Path | |
|---|---|
| `Sources/ClaudeBar/main.swift` | the `NSPanel` overlay, placement, LaunchAgent-friendly lifecycle |
| `Sources/ClaudeBar/BarView.swift` | SwiftUI meters, polling store |
| `Sources/ClaudeBar/UsageClient.swift` | the usage request and `limits` parsing |
| `Sources/ClaudeBar/Credentials.swift` | keychain / credentials-file token read |
