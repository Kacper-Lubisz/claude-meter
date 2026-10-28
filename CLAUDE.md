# Claude Meter: notes for whoever picks this up next

A macOS menu bar app (Swift, AppKit + SwiftUI, SwiftPM, no Xcode project). It shows the usage of Claude's **5-hour** and **weekly** rate-limit windows, a forecast of where each will be at reset, and when you'd run out. It also compares days, weeks and 5-hour windows. All forecast time maths counts **working hours only**. The same core builds on Linux as the `claude-meter` command, which a GNOME Shell extension draws in the top bar. Read `README.md` for the user-facing behaviour. This file covers how it's built, why, and how to work on it safely.

## Commands

```sh
swift build                    # debug build (app + command)
scripts/test.sh                # tests (use this, not `swift test`; see Gotchas)
scripts/install.sh             # release build -> ~/Applications/Claude Meter.app, (re)start via launchd
scripts/install.sh uninstall
.build/debug/ClaudeMeter --preview out.png          # render every bar style, light + dark (uses live API once)
.build/debug/ClaudeMeter --preview-popover out.png  # render every popover tab, light + dark, sample data only
.build/debug/claude-meter --demo                    # the command's report on sample data (add --json for the extension's input)
scripts/check-linux.sh                              # Docker: Linux build + tests, then the GNOME extension in headless GNOME Shell
tail -f ~/Library/Logs/ClaudeMeter.log              # fetch errors
```

## Layout

```
Sources/MeterCore/           pure logic, unit-tested, Foundation only (builds on Linux)
  WorkSchedule.swift         working-hours calendar: workingSeconds(from:to:), date(addingWorkingSeconds:…)
  Forecast.swift             burn rate, projection, runs-out time, PaceStatus (ok / warn / over)
  UsageClient.swift          GET /api/oauth/usage + parsing; UsageError, LimitKind, UsageSnapshot
  Credentials.swift          Claude Code's token: Keychain via `security` (macOS), ~/.claude/.credentials.json (Linux)
  Paths.swift                config / data / Claude Code directories per platform (XDG on Linux)
  Config.swift               MeterConfig (config.json), Sample + History (history.jsonl), LastSnapshot, FetchStatus
  Meter.swift                the engine both front ends use: load, canFetch, record(result), forecast
  Trends.swift               history -> UsageWindows (with early resets), daily weekly-limit use, WindowComparison
  TimeAxis.swift             chart x positions, optionally squeezing time outside working hours; day and clock ticks
  Format.swift               all user-facing wording (%, deltas, dates, verdicts)
  Report.swift               the command's output: panel items + menu sections, as text or JSON
  SampleData.swift           seeded fake history for previews, --demo and the Linux check
  Version.swift              Version.current, and whether the checkout this was built from has a later one
Sources/ClaudeMeterCLI/      `claude-meter` command (main.swift)
Sources/ClaudeMeter/         the macOS app (target only exists on macOS; see Package.swift)
  main.swift                 AppDelegate: status item, popover, --preview modes, log()
  MeterModel.swift           wraps Meter: polling timers, plus the popover's tab and picked baselines
  StatusImage.swift          draws the menu bar item as an NSImage (3 BarStyles)
  PopoverView.swift          SwiftUI popover: tab picker, WindowCard per window, Track bar
  CompareViews.swift         Days / Weeks / 5h windows tabs: OverlayChart, DayBars, window lists; WorkBands,
                             ResetMarks and .timeAxis() for every time chart; SqueezeToggle
  Palette.swift              popover colours (contrast-checked; see Design rules)
gnome/claude-meter@kacperlubisz.com/   GNOME Shell extension (GNOME 45+): runs the command, draws its JSON
Tests/MeterCoreTests/        Swift Testing; calendar, forecast, parsing, trends, persistence, report
scripts/install.sh, install-linux.sh, test.sh, check-linux.sh (+ linux-check/ for its Docker image)
```

## How it works

**Data.** `UsageClient.fetch()` gets the token from `Credentials` and calls `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer …` and `anthropic-beta: oauth-2025-04-20`. On macOS the token comes from `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`. On Linux (or if the Keychain has nothing) it comes from `$CLAUDE_CONFIG_DIR/.credentials.json` or `~/.claude/.credentials.json`. Both hold JSON with `claudeAiOauth.accessToken` and `expiresAt`.
- It uses only `five_hour` and `seven_day`: `utilization` is a 0–100 percentage, and `resets_at` is ISO 8601 with microseconds, which `ISO8601DateFormatter` can't parse until the fraction is stripped.
- The response has many other keys, mostly null. Ignore them unless asked.
- 401 or 403 becomes `loginExpired`, and 429 becomes `rateLimited(retryAfter:)`.

**Token.** It's read, never written or refreshed. Refreshing would rotate Claude Code's refresh token and could log Claude Code out. On macOS it goes through `/usr/bin/security` rather than the Security framework, because the Keychain item's access list already trusts `security`, so there's no prompt.

**Engine.** `Meter` (in MeterCore) holds config, the last snapshot, history, `FetchStatus` and the derived `Trends`. Both front ends go through it, so they poll, back off and save the same way. `record(_:at:)` takes a fetch result. On success it appends a `Sample` (usage *and* both reset times) to `history.jsonl`, saves `last.json` and clears the error. On a 429 it sets `backoffUntil` (`Retry-After`, or 5 minutes) and saves it in `status.json`, so a restart or the next command run still waits.

**Polling.**
- macOS app: a timer every `pollSeconds` (default 120, minimum 60) calls `canFetch(now:)`, which only checks the backoff. Opening the popover refreshes if the last *attempt* is over 60 seconds old.
- The command: each run fetches only if the last attempt is at least `pollSeconds − 10` old (`refresh` ignores that, not the backoff). The GNOME extension runs it every 30 seconds, so most runs just recompute forecasts from saved data.
- A 30-second tick moves `now` forward so forecasts and countdowns update between polls.
- `last.json` is loaded at launch. Any window whose reset has passed is dropped from it.

**History.** `history.jsonl`, one `Sample` per line, appended on each success. Lines that don't parse are skipped. It keeps `History.retention` (42 days), pruned on load and then about daily. Before October 2026 it was `history.json`, one array of 8 days without reset times. `History.load` *merges* that file into the new one and deletes it, and does so whenever it exists, not only when the new file is missing. An old build that's still running keeps rewriting it until it's restarted, and on 23 Oct 2026 a stray load had already created `history.jsonl` from a partial copy.

**Comparisons** (`Trends`):
- *Windows* are split from history by reset time, treating resets within an hour as the same window, because the reported time wobbles (02:59:59 vs 03:00:00; `Format.moment` rounds to the minute so both show as 03:00). Readings without reset times (the old format) split where usage drops or after a gap longer than the window. A window's start is `resetsAt − length`.
- The weekly window is a **fixed cycle**, not anchored to first use. On 27 Oct 2026 it rolled over at exactly 03:00 UTC with no use, and the API reported the next reset (3 Nov 03:00) straight away at 0%. The 5-hour window is different: between windows the API returns no `five_hour` at all, and the next one opens on first use.
- *Early resets* (Anthropic resetting everyone's usage before it's due): a fall of more than 1.5 points within one window's reset time is an `EarlyReset` inside it. A reading with a new reset time before the old one came due ends the old window there (its `resetsAt` becomes the actual end) and the new one gets `openedEarly`. Neither had happened in the real history by 28 Oct 2026; `SampleData` has one (the previous week's Thursday 12:00) so previews show the markers.
- `UsageWindow.progress` is cumulative *use*: from 0 at the opening when it's known, and carrying on past an early reset instead of dropping. `used` is its last value, so totals and comparisons stay meaningful across a reset. Charts of past windows draw `progress`; the Now tab's card draws the raw readings (what the limit showed, so it drops at a reset).
- `UsageWindow.used(after:)` is a step lookup: the last reading at or before that point. Like the days, use between two readings counts at the later one, so a gap (Mac asleep, history not started yet) doesn't spread use over hours nobody worked. Charts use `.stepEnd` to match. `WindowComparison` compares the subject's latest reading with the baseline at the same offset while the subject is open, and whole windows once it's closed.
- *Daily use* is in % of the **weekly** limit: each rise in weekly usage between consecutive readings (`weekUse`), counted at the reading where it shows up. A window with a known opening counts its first reading from 0. Days are bucketed by local midnight, and `hasReadings` separates "0%" from "meter not running". Today is compared by clock time (`sameTime`, DST-safe) with the last working day before it (`defaultBaseline`).
- A 5-hour window's **Of week** is the weekly-limit use between its opening and its end.
- These comparisons use wall-clock time, not working time: windows reset on the wall clock, and days line up by clock time.

**Forecast** (`Forecast.make`):
- The window opens at `resetsAt − length` (5 h or 7 d).
- `elapsed` = working seconds from that opening to now, and `remaining` = working seconds from now to reset.
- `rate` = utilization ÷ max(elapsed, 15 min). The 15-minute floor stops the rate spiking right after a window opens or after out-of-hours use.
- `projected` = utilization + rate × remaining.
- Status: **over** if utilization ≥ 100 or projected > 100. **warn** if projected ≥ 90. Otherwise **ok**.
- `runsOutAt` walks working time forward from now until the projection hits 100%. It's nil if that's after reset.
- Out-of-hours time is simply not counted, so in the evening `remaining` is often 0 and `projected == utilization`. That's intended: the user doesn't work then.

**Version check.** `Version.current` is the one version number: `install.sh` copies it into the bundle's `CFBundleShortVersionString`, and `claude-meter --version` prints it. The installed build finds the checkout it came from through `#filePath` (fixed at compile time), reads `Version.swift` there, and when that version is later (`Version.newerInRepo()`), the popover footer, the GNOME menu and the command's output show `Format.outdated`. The app checks on its 30-second tick, the command on every run. If the checkout has moved or the build was made elsewhere (the Linux check builds in Docker), there's nothing to read and no warning. Added 28 Oct 2026 at the user's request.

**Working schedule** (`WorkSchedule`): ISO weekdays plus `dayStart`/`dayEnd` as `"HH:mm"`, with defaults Mon–Fri 09:00–17:30. Calculations go day by day through `Calendar`, so DST is handled; there's a test on the 25 Oct 2026 UK clock change.

**Bar style** is fixed: `compact` (stacked) unless `barStyle` in config.json says `medium` or `full`. There used to be auto-fitting that picked the widest style that fit beside the notch. On 23 Oct 2026 the user had it removed because the item kept resizing ("it resizes to save space, but it is bad"). Don't bring it back.

## Design rules (decided with the user; don't relitigate)

- **The bar design is settled.** It has a dot, then per window a label, mini bar, %, and (in the wide styles) deadline. On 22 Oct 2026 the user saw five alternatives (alert pill, twin rings, pace gauge, batteries, spinning spark) and rejected all of them: "The current thing is fine." Don't redesign the bar unless asked.
- **Mini bar = used fill + vertical time tick** (`Forecast.elapsedFraction`, in working time), in both the menu bar and the popover's `Track`. On 23 Oct 2026 this replaced the lighter "projected at reset" fill at the user's request. The projection is still shown in the popover rows and chart, and the red cap still marks an overshoot.
- **The bar must show both windows**, the urgency colour (orange = warning, red = danger), and the forecast. The user explicitly wanted urgency colour and high contrast.
- **Contrast is a hard requirement.** In the menu bar, use `.labelColor` for text and labels, not `.secondaryLabelColor`, which the user found almost invisible. In the popover, every colour comes from `Palette`. The popover paints its own opaque background, so contrast doesn't depend on what shows through the material. Text colours measure at least 5.1:1 (most 7:1+) in both appearances; re-check with a WCAG contrast calculation if you change them. Don't use `.green`, `.orange`, `.secondary`, `.quaternary`, or `.accentColor` in the popover.
- **Working hours exclusion is the point of the forecast.** Weekends and time after 17:30 must never count. The user's goal is that the window isn't treated as longer than the time they'll actually work.
- **Working hours are shaded on every time chart, and off-hours can be squeezed.** On 28 Oct 2026 the user asked for working days to stand out in the week chart and for non-working hours to take less of the x axis ("axis crime!"). `TimeAxis` maps time to x. With the **Squeeze off-hours** checkbox ticked (default on, held in `MeterModel`, not saved) it uses `TimeAxis.squeezed`: evenings and nights at 15% of their width, and whole days off at 3%. Days off got their own weight the same day, at the user's request: at 15%, Friday 17:30 to Monday 09:00 was still wider than a working day. It applies to the Days chart, the Weeks chart and the Now tab's week chart. The 5-hour charts are always to scale. Windows are lined up by time since each opened, placed on the subject's axis.
- **Comparisons live in popover tabs** (Now / Days / Weeks / 5h windows), added 23 Oct 2026 at the user's request ("compare days, compare weeks, … how each 5hr window compares to the prior"). The current period is `Palette.accent` and the baseline `Palette.muted` everywhere: charts, legend, and the list dots. Clicking a day bar or a list row changes the baseline. A web app is still parked.
- **Linux front end = GNOME Shell extension over the command's JSON.** All maths and wording live in MeterCore (`Report`), so the JS only lays out rows. Keep it that way: add fields to `Report` rather than logic to `extension.js`. In the extension, the two live windows are inline and the comparison sections (`kind: "comparison"`) are submenus, because otherwise the menu is taller than a screen.

## Verifying UI changes

The terminal running Claude has **no Screen Recording permission**, so `screencapture` fails ("could not create image from rect"). Instead:
- Bar: `.build/debug/ClaudeMeter --preview out.png` renders every style in light and dark, with live data plus a synthetic danger state. Then Read the PNG.
- Popover: `.build/debug/ClaudeMeter --preview-popover out.png` renders the real `PopoverView` in an offscreen window, with sample on-track and warning/danger states, and the Weeks tab both squeezed and to scale. It makes no API calls. With `CLAUDE_METER_DATA_DIR` set it renders that folder's history instead: copy `~/Library/Application Support/ClaudeMeter` somewhere first and point it there, since loading can prune or migrate the history.
- `sips --cropOffset 0 0` is ignored (it centre-crops), so start crops of the preview grid at offset 1.

- Linux / GNOME: `scripts/check-linux.sh` builds and tests on Linux in `swift:6.4`. It then starts GNOME Shell 50 headless (Ubuntu 26.04 image, `--unsafe-mode` so Eval and Screenshot work over D-Bus), loads the extension with the real command behind a `--demo` stub, and screenshots the panel, the menu and each submenu in the dark and light styles into `.build/linux-check/`. It fails on any `JS ERROR`. It hasn't been run on a real GNOME desktop yet.

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
- **No SwiftUI `@State`.** In the macOS 27 SDK it's a macro, and the Command Line Tools don't ship `SwiftUIMacros` ("plugin for module 'SwiftUIMacros' not found"). View state (tab, picked baselines) lives in `MeterModel` as `@Published` instead. `@ObservedObject` and `@Published` are fine.
- **Previews must not load real data.** `AppDelegate.model` is `lazy`, so `--preview`/`--preview-popover` never call `Meter.load()` on the real folder, which can migrate or prune the history. Build preview models with `MeterModel(meter:)`. The only exception is `--preview-popover` with `CLAUDE_METER_DATA_DIR` set, which should point at a copy.
- **Swift Charts axis labels at the very edge get dropped** when centred on their value. `.timeAxis()` anchors a label at x = 0 by its leading edge.
- **Test dates and the clock change.** Windows are exact multiples of 3600 s, so a weekly window that crosses 25 Oct 2026 opens at 05:00 BST when it resets at 04:00 GMT. Pick test weeks that don't cross a clock change, unless that's what's being tested.
- **GNOME menu rows are `reactive: false`,** which GNOME styles as `:insensitive` (dimmed). Every text class in the stylesheets sets an explicit colour. GNOME loads `stylesheet-light.css` *instead of* `stylesheet.css` in the light shell style, so change both. The top bar stays dark in both.
- **Linux networking** needs `import FoundationNetworking` (guarded by `canImport`). Anything Apple-only in MeterCore must sit behind `#if os(macOS)`. `scripts/check-linux.sh` catches it.

## Conventions

- **Bump `Version.current` in `Sources/MeterCore/Version.swift` with every change**: the minor number for features, the patch for fixes. The out-of-date warning only fires when it moves. Keep the declaration on one line in this form, `public static let current = "x.y.z"`: `Version.declared(in:)` and `install.sh` both read it with a simple match.
- Keep `MeterCore` free of AppKit and SwiftUI, and building on Linux. Add a test for any change to the calendar, forecast, parsing, trends or persistence. Tests use `Europe/London` with fixed dates; 2026-10-19 is a Monday.
- User-facing copy is plain and specific ("runs out Fri 16:10", not "capacity exhaustion predicted").
- The repo is private: github.com/Kacper-Lubisz/claude-meter. Commits end with a `Co-Authored-By` line.
