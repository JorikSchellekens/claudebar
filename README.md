# ClaudeBar

A small always-on-top bar pinned to the bottom of the macOS screen showing how
much Claude usage you have left.

```
  claude used   5h ▰▱▱▱▱ 1% 3h 19m   Week ▰▰▱▱▱ 33% 1d 19h   Fable ▰▱▱▱▱ 23% 1d 19h
```

Each meter is a percentage plus the countdown to when that window resets. It
shows percent **used** by default, matching Claude Code's own `/usage`;
right-click to switch to percent **left**. Colour always tracks headroom -
green above 30% left, amber below, red below 10%.

## What it reads

It calls `https://api.anthropic.com/api/oauth/usage` - the same endpoint
Claude Code's `/usage` command uses - and renders the `limits` array it returns
(the session window, the weekly all-model window, and any per-model weekly
window).

Polls once a minute, and again on wake from sleep.

## Install

```sh
./install.sh
./set-token.sh     # optional but recommended, see below
```

`install.sh` builds a release binary, packages `~/Applications/ClaudeBar.app`,
and installs a LaunchAgent (`com.jorikschellekens.claudebar`) with `RunAtLoad`
and `KeepAlive`, so it starts at login and restarts if it ever dies.

## Auth, and how to stop the keychain prompts

With no setup, ClaudeBar borrows the OAuth token Claude Code keeps in your
login keychain under `Claude Code-credentials`. That works immediately, but
Claude Code rotates the token about hourly and rewrites the keychain item each
time, which resets the item's ACL - so macOS keeps asking for permission no
matter how often you click *Always Allow*.

To stop that for good, give ClaudeBar a token of its own:

```sh
claude setup-token     # prints a long-lived token
./set-token.sh         # paste it in
```

`set-token.sh` verifies the token against the usage endpoint, then stores it in
a keychain item that ClaudeBar itself is on the ACL of, so reading it never
prompts. Claude Code's own credentials are left completely alone.

The token is resolved in that order - ClaudeBar's own item, then
`~/.claude/.credentials.json`, then Claude Code's item - and cached in memory
until it expires, so a 60-second poll is not a 60-second keychain hit. On a
401 the cache is dropped and the source re-read once.

ClaudeBar never refreshes or rewrites Claude Code's token; rotating it would
pull it out from under Claude Code.

## Using it

- **Drag** the pill anywhere; the position is remembered.
- **Click** it to refresh immediately.
- **Right-click** to switch used/left, refresh, reset position, or quit.

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
