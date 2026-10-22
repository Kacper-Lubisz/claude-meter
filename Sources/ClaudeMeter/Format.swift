import Foundation
import MeterCore

enum Format {
    static func percent(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    static func rate(_ v: Double) -> String { String(format: "%.1f%% / work hr", v) }

    /// "1h53", "12m", or "4d 13h".
    static func countdown(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        if m >= 24 * 60 { return "\(m / 1440)d \((m % 1440) / 60)h" }
        if m >= 60 { return "\(m / 60)h\(String(format: "%02d", m % 60))" }
        return "\(m)m"
    }

    static func workHours(_ seconds: TimeInterval) -> String {
        String(format: "%.1f work hrs", seconds / 3600)
    }

    /// "16:10" today, otherwise "Fri 16:10".
    static func moment(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }

    /// The short deadline shown in the menu bar: when you'll run out, else when it resets.
    static func barDeadline(_ f: Forecast, now: Date) -> String {
        if let out = f.runsOutAt { return moment(out, now: now) }
        let left = f.resetsAt.timeIntervalSince(now)
        if left < 24 * 3600 { return countdown(left) }
        let d = DateFormatter(); d.dateFormat = "EEE"
        return "↻" + d.string(from: f.resetsAt)
    }
}
