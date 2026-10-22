# Claude Meter

A macOS menu bar meter for your Claude plan's **5-hour** and **weekly** limits. It shows how much you've used, your burn rate, when each window resets, and whether you're on course to run out before it does. Burn rate only counts your working hours.

```
● 5H [■■■■■▒▒▒░░] 41% 1h53    WK [■■■■▒▒▒▒▒▒]▌ 71% Fri 10:12
```

## Reading the bar

| Part | Meaning |
|---|---|
| **Dot** | The more urgent of the two windows. Green: on track. Orange: on course to finish at 90–100% by reset. Red: on course to run out (over 100%) before reset. |
| **Solid bar** | Used so far. |
| **Light bar** | Where you'll be at reset at your current pace. |
| **Red cap** | Projected to go over 100%. |
| **%** | Used so far. Coloured orange or red when that window is the problem. |
| **Small text** | Time until reset (`1h53`, or `↻Tue` if more than a day away). Or, in red, when you'll run out at your current pace. |

**It narrows itself to fit.** There are three widths:
- **Full:** the line above, about 300pt.
- **Medium:** shorter bars, and the deadline only appears when you're on course to run out. About 180pt.
- **Compact:** both windows stacked, about 85pt.

It picks the widest one that fits between the notch (or screen edge) and your other menu bar items.

**Click it** for the detail. For each window you get the burn rate (% per working hour), the projection at reset, working hours left, the pace you can afford to finish at exactly 100%, and a chart of the window so far with the projection dashed.

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
  "barStyle" : "auto",
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
- `barStyle`: `auto`, `full`, `medium`, or `compact`.
- `pollSeconds`: how often to ask the API. The minimum is 60. Don't go much lower, because the endpoint rate-limits.

## Install, update, remove

Needs macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

```sh
scripts/install.sh            # build, install to ~/Applications/Claude Meter.app, start now and at login
scripts/install.sh uninstall  # stop and remove (keeps config and history)
scripts/test.sh               # unit tests
```

Re-run `scripts/install.sh` after pulling changes. To work on it, start with `CLAUDE.md`.

## Where the data comes from

It reads `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code's `/usage`. It authenticates with the OAuth login Claude Code keeps in the macOS Keychain (`Claude Code-credentials`). The token is read with `/usr/bin/security` on each poll and is never stored, logged, or refreshed by this app. If it has expired, open Claude Code and it will refresh the login.

This endpoint isn't documented and may change. Parsing lives in `Sources/MeterCore/UsageClient.swift`.

## Files

| Path | What |
|---|---|
| `~/.config/claude-meter/config.json` | Settings |
| `~/Library/Application Support/ClaudeMeter/history.json` | Readings from the last 8 days, for the charts |
| `~/Library/Application Support/ClaudeMeter/last.json` | Last reading, shown immediately on launch |
| `~/Library/Logs/ClaudeMeter.log` | Fetch errors and bar-width decisions |
| `~/Library/LaunchAgents/com.kacper.claude-meter.plist` | Starts it at login |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Bar says `Claude ⚠` | No reading yet and the last fetch failed. Hover for the reason, or check the log. |
| "Rate limited by the usage API" | It backs off (honouring `Retry-After`, otherwise 5 minutes) and keeps showing the last reading. |
| "Login has expired" | Open Claude Code once. |
| Item missing from the menu bar | It doesn't fit even in compact mode. Remove other items, or check the log for `still hidden`. |
