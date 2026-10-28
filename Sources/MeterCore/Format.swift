import Foundation

/// User-facing wording, shared by the macOS popover and the `claude-meter` command (and so the GNOME extension).
public enum Format {
    public static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    public static func rate(_ v: Double) -> String { String(format: "%.1f%% / work hr", v) }

    /// "+11", "−4" or "±0" percentage points.
    public static func delta(_ d: Double) -> String {
        let n = Int(d.rounded())
        return n > 0 ? "+\(n)" : n < 0 ? "−\(-n)" : "±0"
    }

    /// "1h53", "12m", or "4d 13h".
    public static func countdown(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        if m >= 24 * 60 { return "\(m / 1440)d \((m % 1440) / 60)h" }
        if m >= 60 { return "\(m / 60)h\(String(format: "%02d", m % 60))" }
        return "\(m)m"
    }

    public static func workHours(_ seconds: TimeInterval) -> String {
        String(format: "%.1f work hrs", seconds / 3600)
    }

    static func date(_ d: Date, _ pattern: String, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: d)
    }

    /// "16:10" today, otherwise "Fri 16:10". To the nearest minute: the API reports some resets
    /// as 02:59:59 and others as 03:00:00.
    public static func moment(_ d: Date, now: Date, calendar: Calendar = .current) -> String {
        let d = Date(timeIntervalSinceReferenceDate: (d.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        return date(d, calendar.isDate(d, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm", calendar: calendar)
    }

    /// "Today", "Yesterday", or "Thu 22" (lower-case "today" and "yesterday" mid-sentence).
    public static func day(_ d: Date, now: Date, calendar: Calendar = .current, midSentence: Bool = false) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return midSentence ? "today" : "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) {
            return midSentence ? "yesterday" : "Yesterday"
        }
        return date(d, "EEE d", calendar: calendar)
    }

    /// "16:10", for chart axes.
    public static func clock(_ d: Date, calendar: Calendar = .current) -> String { date(d, "HH:mm", calendar: calendar) }

    /// "Mon", for chart axes.
    public static func weekday(_ d: Date, calendar: Calendar = .current) -> String { date(d, "EEE", calendar: calendar) }

    /// "Tue 13 Oct", for the start of a weekly window.
    public static func weekStart(_ d: Date, calendar: Calendar = .current) -> String { date(d, "EEE d MMM", calendar: calendar) }

    /// The headline next to a window's percentage.
    public static func verdict(_ f: Forecast, now: Date) -> String {
        if f.utilization >= 100 { return "limit reached" }
        if let out = f.runsOutAt { return "runs out \(moment(out, now: now))" }
        return f.status == .warn ? "cutting it close" : "on track"
    }

    /// The short deadline shown in the menu bar: when you'll run out, else when it resets.
    public static func barDeadline(_ f: Forecast, now: Date) -> String {
        if let out = f.runsOutAt { return moment(out, now: now) }
        let left = f.resetsAt.timeIntervalSince(now)
        if left < 24 * 3600 { return countdown(left) }
        return "↻" + weekday(f.resetsAt)
    }

    /// "Wed 14:02 · 58% back".
    public static func earlyReset(_ r: EarlyReset, now: Date, calendar: Calendar = .current) -> String {
        "\(moment(r.at, now: now, calendar: calendar)) · \(percent(r.givenBack)) back"
    }

    /// "Out of date: this is 0.2.0, the repo has 0.3.0.", then on its own line "Run scripts/install.sh to update."
    public static func outdated(repo: String, running: String = Version.current) -> String {
        #if os(macOS)
        let script = "scripts/install.sh"
        #else
        let script = "scripts/install-linux.sh"
        #endif
        return "Out of date: this is \(running), the repo has \(repo).\nRun \(script) to update."
    }

    /// "30% → 41% (+11)": the baseline at the same point, the subject, and the change.
    public static func comparison(_ c: WindowComparison) -> String {
        guard let then = c.baselineUsed, let d = c.delta else { return "–" }
        return "\(percent(then)) → \(percent(c.subject.used)) (\(delta(d)))"
    }
}
