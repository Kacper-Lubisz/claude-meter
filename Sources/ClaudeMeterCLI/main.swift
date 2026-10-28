import Foundation
import MeterCore

let usage = """
    Usage: claude-meter [status] [--json] [--offline] [--demo]
           claude-meter refresh [--json]

      status     Usage, forecasts, and comparisons of days, weeks and 5-hour windows (the default).
                 Asks the usage API for a new reading if the last one is older than pollSeconds.
      refresh    Ask for a new reading now. Still waits out a rate-limit backoff.
      --json     What the GNOME extension draws, as JSON.
      --offline  Don't ask the API; use the saved readings.
      --demo     Made-up data: no login, no API calls, nothing saved.
      --version  This build's version.
    """

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
if flag("--help") || flag("-h") { print(usage); exit(0) }
if flag("--version") { print(Version.current); exit(0) }
let json = flag("--json"), offline = flag("--offline"), demo = flag("--demo")
let command = args.first ?? "status"
guard args.count <= 1, ["status", "refresh"].contains(command) else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

var now = Date()
var meter: Meter
if demo {
    now = SampleData.now()
    meter = SampleData.meter(now: now)
} else {
    meter = Meter.load(now: now)
    // The GNOME extension runs this every 30 seconds; only every pollSeconds of those should reach the API.
    let minInterval = command == "refresh" ? 0 : max(60, meter.config.pollSeconds) - 10
    if !offline, meter.canFetch(now: now, minInterval: minInterval) {
        let result = await UsageClient().result()
        now = Date()
        meter.record(result, at: now)
    }
}

let report = Report(meter: meter, now: now, newerVersion: Version.newerInRepo())
print(json ? report.json() : report.text)
