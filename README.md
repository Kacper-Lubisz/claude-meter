# Claude Meter

A macOS menu bar meter for your Claude plan's **5-hour** and **weekly** limits. It shows the burn rate, when each window resets, and whether you're on course to run out before it does.

```
5H [■■■■■▒▒▒░░] 41% 1h53    WK [■■■■▒▒▒▒▒▒]▌ 38% Fri 16:10
```

- **Solid**: used so far. **Light**: projected at reset at your current pace. **Red cap**: projected to go over 100%.
- **Small text**: time until reset, or when you'll run out if you're on course to. Red means you'll run out.
- **It narrows itself to fit.** There are three styles. Full is the line above. Medium has shorter bars and only shows a deadline when you're on course to run out. Compact stacks both windows in about 70pt. By default it uses the widest one that fits between the notch (or screen edge) and your other menu bar items.
- Click it for the detail: burn rate (% per working hour), projection at reset, working time left, the pace you can afford to finish at 100%, and a chart of the window so far.

## Working hours

Burn rate and projections only count **working time**. Weekends and time outside the working day count as zero, so evenings and weekends don't make your pace look slower than it is, and the forecast doesn't assume you'll keep working through them.

Edit `~/.config/claude-meter/config.json` (or click **Settings** in the popover), then restart the app:

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

`workdays` uses ISO numbering (1 = Monday, 7 = Sunday). `barStyle` is `auto`, `full`, `medium`, or `compact`.

Logs (including which bar style was picked and why) go to `~/Library/Logs/ClaudeMeter.log`. `ClaudeMeter --preview out.png` renders every style in light and dark.

## Install

Needs macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode isn't required.

```sh
scripts/install.sh            # build, install to ~/Applications, start at login
scripts/install.sh uninstall  # remove
swift test                    # forecast and calendar tests
```

## Where the data comes from

It reads the same endpoint as Claude Code's `/usage` (`api.anthropic.com/api/oauth/usage`), using the OAuth login Claude Code keeps in your Keychain (`Claude Code-credentials`). The token is read with `/usr/bin/security` and is never stored, logged, or refreshed by this app. If it has expired, open Claude Code and it will refresh the login.

This is an undocumented endpoint, so it may change. If it does, parsing lives in `Sources/MeterCore/UsageClient.swift`.

Each poll is appended to `~/Library/Application Support/ClaudeMeter/history.json` (eight days kept) for the charts.
