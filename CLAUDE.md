# Claude Meter: notes for whoever picks this up next

A macOS menu bar app (Swift, AppKit + SwiftUI, SwiftPM, no Xcode project). It shows the usage of Claude's **5-hour** and **weekly** rate-limit windows, a forecast of where each will be at reset, and when you'd run out. All time maths counts **working hours only**. Read `README.md` for the user-facing behaviour. This file covers how it's built, why, and how to work on it safely.

## Commands

```sh
swift build                    # debug build
scripts/test.sh                # tests (use this, not `swift test`; see Gotchas)
scripts/install.sh             # release build -> ~/Applications/Claude Meter.app, (re)start via launchd
scripts/install.sh uninstall
.build/debug/ClaudeMeter --preview out.png          # render every bar style, light + dark (uses live API once)
.build/debug/ClaudeMeter --preview-popover out.png  # render the popover, light + dark, sample data only
tail -f ~/Library/Logs/ClaudeMeter.log              # fetch errors + bar-width decisions
```

## Layout

```
Sources/MeterCore/           pure logic, unit-tested, no AppKit
  WorkSchedule.swift         working-hours calendar: workingSeconds(from:to:), date(addingWorkingSeconds:…)
  Forecast.swift             burn rate, projection, runs-out time, PaceStatus (ok / warn / over)
  UsageClient.swift          Keychain token read + GET /api/oauth/usage + parsing; UsageError
  Config.swift               MeterConfig (config.json), History (history.json), LastSnapshot (last.json)
Sources/ClaudeMeter/         the app
  main.swift                 AppDelegate: status item, popover, bar-width fitting, --preview modes, log()
  MeterModel.swift           polling, 429 backoff, state for the views
  StatusImage.swift          draws the menu bar item as an NSImage (3 BarStyles)
  PopoverView.swift          SwiftUI popover: WindowCard per window, Track bar, Swift Charts chart
  Palette.swift              popover colours (contrast-checked; see Design rules)
  Format.swift               %, countdowns, dates
Tests/MeterCoreTests/        Swift Testing; calendar, forecast, parsing, persistence
scripts/install.sh, test.sh
```

## How it works

**Data.** `UsageClient.fetch()` runs `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`, reads `claudeAiOauth.accessToken`, and calls `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer …` and `anthropic-beta: oauth-2025-04-20`.
- It uses only `five_hour` and `seven_day`: `utilization` is a 0–100 percentage, and `resets_at` is ISO 8601 with microseconds, which `ISO8601DateFormatter` can't parse until the fraction is stripped.
- The response has many other keys, mostly null. Ignore them unless asked.
- 401 or 403 becomes `loginExpired`, and 429 becomes `rateLimited(retryAfter:)`.

**Token.** It's read, never written or refreshed. Refreshing would rotate Claude Code's refresh token and could log Claude Code out. It goes through `/usr/bin/security` rather than the Security framework, because the Keychain item's access list already trusts `security`, so there's no prompt.

**Polling.**
- Every `pollSeconds` (default 120, minimum 60).
- Opening the popover refreshes only if the reading is more than 60 seconds old.
- After a 429, no requests are made until `Retry-After`, or for 5 minutes.
- A 30-second tick moves `now` forward so forecasts and countdowns update between polls.
- Each success is appended to `history.json` (8 days kept) and saved to `last.json`, which is loaded at launch. Any window whose reset has passed is dropped from it.

**Forecast** (`Forecast.make`):
- The window opens at `resetsAt − length` (5 h or 7 d).
- `elapsed` = working seconds from that opening to now, and `remaining` = working seconds from now to reset.
- `rate` = utilization ÷ max(elapsed, 15 min). The 15-minute floor stops the rate spiking right after a window opens or after out-of-hours use.
- `projected` = utilization + rate × remaining.
- Status: **over** if utilization ≥ 100 or projected > 100. **warn** if projected ≥ 90. Otherwise **ok**.
- `runsOutAt` walks working time forward from now until the projection hits 100%. It's nil if that's after reset.
- Out-of-hours time is simply not counted, so in the evening `remaining` is often 0 and `projected == utilization`. That's intended: the user doesn't work then.

**Working schedule** (`WorkSchedule`): ISO weekdays plus `dayStart`/`dayEnd` as `"HH:mm"`, with defaults Mon–Fri 09:00–17:30. Calculations go day by day through `Calendar`, so DST is handled; there's a test on the 25 Oct 2026 UK clock change.

**Bar width fitting** (`AppDelegate.redraw` / `scheduleFitCheck`). macOS gives no "doesn't fit" signal. On notched MacBooks, an item behind the notch still reports itself as on-screen and visible. So:
1. *Predictive:* if the item is currently visible, the space it has is `window.frame.maxX − screen.auxiliaryTopRightArea.minX` (the notch's right edge), or the screen's left edge on displays without a notch. The item's right edge doesn't move when its width changes, so the app picks the widest `BarStyle` that fits. This works in both directions.
2. *Fallback:* 0.6 s after any redraw, if the item isn't visible (off screen, or overlapping the notch span between `auxiliaryTopLeftArea.maxX` and `auxiliaryTopRightArea.minX`), it steps down one style.

On display changes or screen wake it resets to full and fits again. Every decision is logged. On the user's 14" MacBook (1470pt wide, notch spanning x 645–824) it usually lands on **medium**.

## Design rules (decided with the user; don't relitigate)

- **The bar design is settled.** It has a dot, then per window a label, mini bar, %, and deadline, in the three widths. On 22 Oct 2026 the user saw five alternatives (alert pill, twin rings, pace gauge, batteries, spinning spark) and rejected all of them: "The current thing is fine." Don't redesign the bar unless asked.
- **The bar must show both windows**, the urgency colour (orange = warning, red = danger), and the forecast. The user explicitly wanted urgency colour and high contrast.
- **Contrast is a hard requirement.** In the menu bar, use `.labelColor` for text and labels, not `.secondaryLabelColor`, which the user found almost invisible. In the popover, every colour comes from `Palette`. The popover paints its own opaque background, so contrast doesn't depend on what shows through the material. Text colours measure at least 5.1:1 (most 7:1+) in both appearances; re-check with a WCAG contrast calculation if you change them. Don't use `.green`, `.orange`, `.secondary`, `.quaternary`, or `.accentColor` in the popover.
- **Working hours exclusion is the point of the forecast.** Weekends and time after 17:30 must never count. The user's goal is that the window isn't treated as longer than the time they'll actually work.
- **Graphs or a web app** were raised at the start and parked ("Later"). `history.json` is already collected for them.

## Verifying UI changes

The terminal running Claude has **no Screen Recording permission**, so `screencapture` fails ("could not create image from rect"). Instead:
- Bar: `.build/debug/ClaudeMeter --preview out.png` renders every style in light and dark, with live data plus a synthetic danger state. Then Read the PNG.
- Popover: `.build/debug/ClaudeMeter --preview-popover out.png` renders the real `PopoverView` in an offscreen window, with sample on-track and warning/danger states. It makes no API calls.
- Live placement: read `~/Library/Logs/ClaudeMeter.log`. It records the style chosen and the item's window frame.

Always run a preview with a kill guard: if the binary is stale or doesn't know the flag, it starts a **second real menu bar instance**.

```sh
( .build/debug/ClaudeMeter --preview-popover out.png & p=$!; for i in $(seq 1 40); do kill -0 $p 2>/dev/null || break; sleep 1; done; kill $p 2>/dev/null; wait $p )
```

## Gotchas (each one has bitten already)

- **`swift test` fails with only the Command Line Tools installed** ("plugin for module 'TestingMacros' not found"). The `swiftbuild` backend doesn't search `…/host/plugins/testing`. `scripts/test.sh` passes `-plugin-path`.
- **Don't pipe `swift test | tail`** to judge success: the pipe swallows the exit code. Check `${pipestatus[1]}` or use `scripts/test.sh` directly.
- **Dynamic colours resolve early.** `NSColor.labelColor.withAlphaComponent(x)` in an `NSAttributedString` built *outside* the image's drawing handler is fixed at light-mode values, which made text nearly black in dark mode. In `StatusImage`, use plain dynamic colours in attributed strings, and only call `withAlphaComponent` inside the drawing closure, where the button's appearance is current.
- **`launchctl bootstrap` error 5** happens when it runs before `bootout` has finished. `install.sh` waits for the old job to go first.
- **The usage endpoint rate-limits quickly.** Repeated `--preview` runs, or rapid reinstalls, each fetch once, on top of the app's own polling. Prefer `--preview-popover`, which uses sample data, and leave a few minutes between live-data runs.
- **Quitting from the popover** exits with code 0, and the LaunchAgent (`KeepAlive.SuccessfulExit = false`) deliberately doesn't relaunch it. A crash does relaunch it.
- **Swift 5 language mode** (`swiftLanguageModes: [.v5]`) avoids strict-concurrency noise. AppKit entry points use `MainActor.assumeIsolated`.

## Conventions

- Keep `MeterCore` free of AppKit and SwiftUI, and add a test for any change to the calendar, forecast, or parsing. Tests use `Europe/London` with fixed dates; 2026-10-19 is a Monday.
- User-facing copy is plain and specific ("runs out Fri 16:10", not "capacity exhaustion predicted").
- The repo is private: github.com/Kacper-Lubisz/claude-meter. Commits end with a `Co-Authored-By` line.
