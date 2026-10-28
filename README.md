# Claude Meter

A menu bar meter for your Claude plan's **5-hour** and **weekly** limits. It shows how much you've used, your burn rate, when each window resets, and whether you're on course to run out before it does. Burn rate only counts your working hours. It also compares days, weeks and 5-hour windows with each other.

It's a macOS app. The same logic is also a `claude-meter` command that runs on Linux, with a GNOME Shell extension that puts it in the top bar (see [Linux](#linux-gnome)).

```
● 5h [■■■░|░] 41%
  W  [■■|■░]▌ 71%
```

## Reading the bar

| Part | Meaning |
|---|---|
| **Dot** | The more urgent of the two windows. Green: on track. Orange: on course to finish at 90–100% by reset. Red: on course to run out (over 100%) before reset. |
| **Solid bar** | Used so far. |
| **Vertical tick** | How far through the window you are, in working hours. Fill past the tick means you're using it faster than evenly. |
| **Red cap** | Projected to go over 100%. |
| **%** | Used so far. Coloured orange or red when that window is the problem. |
| **Small text** | Time until reset (`1h53`, or `↻Tue` if more than a day away). Or, in red, when you'll run out at your current pace. |

It shows both windows stacked, about 85pt wide. Two wider single-line layouts are available through `barStyle`:
- **Full:** label, 40pt bar, %, and time to reset or run-out. About 300pt.
- **Medium:** shorter bars, and the deadline only appears when you're on course to run out. About 180pt.

**Click it** for the detail. It has four tabs:

- **Now:** for each window, the burn rate (% per working hour), the projection at reset, working hours left, the pace you can afford to finish at exactly 100%, a chart of the window so far with the projection dashed, and how far the previous window had got by the same point.
- **Days**, **Weeks** and **5h windows:** see [Comparing](#comparing).

## Comparing

Each comparison puts the current period and an earlier one on one chart, lined up by time since each began, so you can see whether you're ahead of or behind where you were. The current one is blue and the earlier one grey.

- **Days:** how much of the **weekly** limit you used each day: today so far, against the last working day by the same time of day. Below are bars for the last 14 days. Click a bar to compare with that day. A day with no bar had no readings, because the meter wasn't running.
- **Weeks:** this weekly window against the one before at the same point in the week, then a list of recent weeks with each one's total and its change on the week before. Click a week to compare with it. A week runs from one reset to the next as the API reports it (for example Tuesday 03:00 to Tuesday 03:00), not Monday to Sunday, and the axis starts on that day.
- **5h windows:** the open 5-hour window against the previous one at the same time since it opened. Below is a list of recent windows with what each used, its change on the window before it, and how much of the weekly limit it took (**Of week**). Click a window to compare with it.

Use is counted at the reading where it first shows up. Use while the meter isn't running (overnight, or on another device) lands on its next reading. History goes back six weeks, so the comparisons fill in as it builds up.

**Working hours are shaded** on every chart. **Squeeze off-hours** (ticked by default, next to the Days and Weeks legends) draws evenings and nights at 15% of their width, and whole days off such as weekends at 3%, on the Days and Weeks charts and the Now tab's week chart. The working days fill about three quarters of a week's chart, and a weekend is a thin gap between Friday and Monday. The axis isn't to scale while it's ticked: use outside working hours shows up as a steep rise in a narrow gap.

**Early resets.** Anthropic occasionally resets everyone's usage before it's due, after an outage, say. The meter spots this when usage drops before the reset time, and marks it with a dashed line and ↺ on the charts, ↺ next to the window in the lists, and a **Reset early** row on the Now tab (when it happened and how much it gave back). The comparisons count what you *used*, so a window's total carries on past an early reset rather than starting again, and you can still compare it with a week that had none. If a reset also moves the reset time, the old window ends there and a new one starts.

## Working hours

Burn rate and projections only count **working time**. Weekends and time outside the working day count as zero. So evenings and weekends don't make your pace look slower than it is, and the forecast doesn't assume you'll keep working through them.

- **Burn rate** = % used ÷ working hours since the window opened (at least 15 minutes is assumed, so a burst of work right at the start doesn't spike it).
- **Projected at reset** = % used + burn rate × working hours left before reset.
- **Runs out at** = the working moment at which the projection crosses 100%.
- **Pace to finish at 100%** = % remaining ÷ working hours left.

## Settings

`~/.config/claude-meter/config.json` is created on first run. You can also open it with **Settings** in the popover. Restart the app after editing it: `scripts/install.sh` restarts it, or use Quit, which launchd won't relaunch, then open `~/Applications/Claude Meter.app`.

```json
{
  "barStyle" : "compact",
  "pollSeconds" : 120,
  "schedule" : {
    "dayEnd" : "17:30",
    "dayStart" : "09:00",
    "workdays" : [1, 2, 3, 4, 5]
  }
}
```

- `workdays`: ISO numbering, 1 = Monday … 7 = Sunday.
- `dayStart` / `dayEnd`: local time, `HH:mm`.
- `barStyle`: `compact` (default), `medium`, or `full`. It never changes on its own.
- `pollSeconds`: how often to ask the API. The minimum is 60. Don't go much lower, because the endpoint rate-limits.

## Install, update, remove

Needs macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

```sh
scripts/install.sh            # build, install to ~/Applications/Claude Meter.app, start now and at login
scripts/install.sh uninstall  # stop and remove (keeps config and history)
scripts/test.sh               # unit tests
```

Re-run `scripts/install.sh` after pulling changes. You'll get a reminder: the installed app compares its version with the one in the repo it was built from, and when the repo's is later, the popover says so in orange above the working hours ("Out of date: this is 0.2.0, the repo has 0.3.0"). It checks every 30 seconds, and stays quiet if the repo has moved or been deleted. The GNOME menu and the command show the same warning. To work on it, start with `CLAUDE.md`.

## Linux (GNOME)

Needs a Swift 6 toolchain ([swiftly](https://www.swift.org/install/linux/) installs one), GNOME Shell 45 or later, and Claude Code logged in.

```sh
scripts/install-linux.sh            # build claude-meter into ~/.local/bin, install and enable the GNOME Shell extension
scripts/install-linux.sh uninstall  # remove both (keeps config and history)
```

GNOME Shell only loads a new extension when it starts, so log out and back in after the first install. Then run `gnome-extensions enable claude-meter@kacperlubisz.com` if it isn't on yet. The top bar shows the dot, then a bar and % for each window, like the macOS bar's `medium` style. Its menu has the two windows' detail, with **Days**, **Weeks** and **5-hour windows** as submenus.

The extension runs `claude-meter status --json` every 30 seconds and draws what it prints. The command only asks the usage API when the last attempt is older than `pollSeconds`.

## The `claude-meter` command

It works on both platforms. On macOS, run it with `swift run claude-meter`.

```sh
claude-meter                  # usage, forecasts and comparisons, in the terminal
claude-meter --json           # the same as JSON (what the GNOME extension draws)
claude-meter refresh          # ask the API now (still waits out a rate-limit backoff)
claude-meter --offline        # don't ask the API; use what's saved
claude-meter --demo           # made-up data: no login, no API calls, nothing saved
claude-meter --version        # this build's version
```

It shares config, history and backoff with the app, so running it alongside the macOS app doesn't double the requests.

## Where the data comes from

It reads `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code's `/usage`. It authenticates with Claude Code's OAuth login. On macOS that's in the Keychain (`Claude Code-credentials`), read with `/usr/bin/security`. On Linux it's `~/.claude/.credentials.json` (or under `$CLAUDE_CONFIG_DIR`). The token is read on each poll and is never stored, logged, or refreshed by this app. If it has expired, open Claude Code and it will refresh the login.

This endpoint isn't documented and may change. Parsing lives in `Sources/MeterCore/UsageClient.swift`.

## Files

| Path (macOS) | Path (Linux) | What |
|---|---|---|
| `~/.config/claude-meter/config.json` | `$XDG_CONFIG_HOME/claude-meter/config.json` | Settings |
| `~/Library/Application Support/ClaudeMeter/history.jsonl` | `$XDG_DATA_HOME/claude-meter/history.jsonl` | Readings from the last six weeks, one per line, for the charts and comparisons |
| `…/last.json` | `…/last.json` | Last reading, shown immediately on launch |
| `…/status.json` | `…/status.json` | How the last request went, so a restart still honours a rate-limit backoff |
| `~/Library/Logs/ClaudeMeter.log` | | Fetch errors |
| `~/Library/LaunchAgents/com.kacper.claude-meter.plist` | `~/.local/share/gnome-shell/extensions/claude-meter@kacperlubisz.com/` | Starts it at login |

`$XDG_DATA_HOME` defaults to `~/.local/share` and `$XDG_CONFIG_HOME` to `~/.config`. Versions before October 2026 kept eight days in `history.json`. That file is merged into `history.jsonl` and removed the first time a newer version loads.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Bar says `Claude ⚠` | No reading yet and the last fetch failed. Hover for the reason, or check the log. |
| "Rate limited by the usage API" | It backs off (honouring `Retry-After`, otherwise 5 minutes) and keeps showing the last reading. |
| "Login has expired" | Open Claude Code once. |
| Item missing from the menu bar | The menu bar is too full, so macOS hid it (on notched MacBooks, behind the notch). Remove other items. |
