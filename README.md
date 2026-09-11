# ClaudeBar

A small always-on-top bar pinned to the bottom of the macOS screen showing how
much Claude usage you have left.

```
  claude   5h ▰▱▱▱▱ 1% 3h 19m   Week ▰▰▱▱▱ 33% 1d 19h   Fable ▰▱▱▱▱ 23% 1d 19h
```

Each meter is a percentage plus how long until that window resets. It shows
percent **used** by default, matching Claude Code's own `/usage`; right-click
to switch to percent **left**. Colour always tracks headroom - green above 30%
left, amber below, red below 10%.

## Pace

Each meter carries a notch: where the fill edge would sit if that window were
being spent evenly. Fill short of the notch means you are under budget for how
far into the window you are. Past it means you are burning faster than the
clock, and the stretch between the notch and the fill edge - the overspend -
is painted one step warmer than the meter itself, amber on a green bar and red
on an amber one. On a bar that is already red it is left alone; there is no
worse colour to go to, and the notch says it anyway.

In percent-**left** mode the bar and the notch both mirror, so the overspend
becomes a gap rather than a stretch of fill - headroom you should still have
and do not. It is painted faintly there, because a solid block of colour in
the empty part of the bar would read as spend.

Hover a meter for the numbers - how much of the window has gone, how much of
the allowance, and where the current rate lands you at reset.

The API gives a percent and a reset time but never says how long the window is,
and without that there is nothing to pace against. The length is measured
instead: time-to-reset is largest the instant a window opens, so the largest
value ever seen for a window *is* its length, converging from below and never
overshooting. Until one has been observed, the product's own windows are used -
5 hours for the session, 7 days for the weekly ones. Measuring off the jump in
`resets_at` would be wrong: a session window starts at your first message after
the last lapsed, so that gap is the window plus however long you were idle.

The notch is hidden in the first 3% of a window, where it would sit on the end
cap and say nothing. Right-click to turn it off entirely.

The pill sits at 40% opacity while everything is under 50% used and fades up to
full by 80%, so it recedes when there is nothing to say. Hovering restores it.

It also posts a notification the first time a window crosses 80%, and again at
95%, re-arming when that window resets.

## What it reads

It calls `https://api.anthropic.com/api/oauth/usage` - the same endpoint
Claude Code's `/usage` command uses - and renders the `limits` array it returns
(the session window, the weekly all-model window, and any per-model weekly
window).

## Polling

Every 5 minutes, and again on wake from sleep. That endpoint rate-limits, and
the windows it reports are measured in hours and days, so polling harder only
earns 429s.

On a failed poll it keeps the last good numbers on screen rather than blanking,
and backs off exponentially (honouring `Retry-After`) up to 30 minutes. The
`claude` label turns amber once the numbers are stale enough to distrust; hover
it for the last-updated time and the reason the last poll failed.

The last reading is cached to disk and reused on launch if it is younger than
the poll interval, so restarting - or a run of reinstalls - does not spend a
request every time.

## Install

```sh
./install.sh
```

`install.sh` builds a release binary, packages `~/Applications/ClaudeBar.app`,
and installs a LaunchAgent (`com.jorikschellekens.claudebar`) with `RunAtLoad`
and `KeepAlive`, so it starts at login and restarts if it ever dies.

## Auth, and the one keychain prompt

ClaudeBar reads the OAuth token Claude Code keeps in your login keychain under
`Claude Code-credentials`. The first time it does, macOS asks for authorization.
**Click "Always Allow" and it stops asking.**

That token is the only one the usage endpoint accepts, and Claude Code keeps it
fresh, so there is nothing to set up and nothing to rotate by hand.

The prompt comes back after a reinstall, and only then: `install.sh` re-signs
the app ad-hoc, which changes its code hash, and the access you granted was tied
to the old hash. Claude Code's own hourly token refresh does *not* bring it back
- it writes with `security add-generic-password -U`, which preserves the item's
ACL. So: one click per reinstall, none in between.

Sources are tried in order - `CLAUDEBAR_TOKEN` in the environment, then
`~/.config/claudebar/token`, then `~/.claude/.credentials.json`, then the
keychain - and the result is cached in memory until it expires, so a 60-second
poll is not a 60-second keychain hit. On a 401 the cache is dropped and the
source re-read once.

ClaudeBar never refreshes or rewrites Claude Code's token; rotating it would
pull it out from under Claude Code.

The file sources come first and never prompt, so if you have a token the usage
endpoint accepts, putting it in `~/.config/claudebar/token` (mode `600`) takes
the keychain out of the picture entirely.

## Using it

- **Drag** the pill anywhere; the position is remembered.
- **Double-click** to send it back to bottom centre.
- **Click** to refresh, unless the numbers are already less than 30s old.
- **Right-click** to switch used/left, toggle the pace notch, refresh, reset
  position, or quit.

It lives on every space and floats over full-screen apps, and sits above the
Dock by default (it is positioned in the screen's visible frame). Position is
stored as a fraction of the visible frame rather than absolute pixels, so it
follows the display your mouse is on and lands in the same relative spot on
screens of different sizes.

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
| `Sources/ClaudeBar/BarView.swift` | SwiftUI meters, polling store, backoff and caching |
| `Sources/ClaudeBar/Pace.swift` | window-length learning and the even-burn comparison |
| `Sources/ClaudeBar/UsageClient.swift` | the usage request and `limits` parsing |
| `Sources/ClaudeBar/Credentials.swift` | token file read, with in-memory caching |
| `Sources/ClaudeBar/Notifier.swift` | 80% / 95% threshold notifications |
