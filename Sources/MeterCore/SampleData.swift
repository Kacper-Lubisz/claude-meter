import Foundation

/// Five weeks of made-up but plausible weekday use, so the popover previews, `claude-meter --demo`
/// and the GNOME extension can be checked without a login or calls to the usage API.
/// Seeded, so it comes out the same every time.
public enum SampleData {
    /// A weekday mid-afternoon, so a 5-hour window is open: the latest weekday at 15:10.
    public static func now(calendar: Calendar = .current, from real: Date = Date()) -> Date {
        var day = calendar.startOfDay(for: real)
        while [1, 7].contains(calendar.component(.weekday, from: day)) {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return calendar.date(bySettingHour: 15, minute: 10, second: 0, of: day)!
    }

    public static func meter(now: Date, calendar: Calendar = .current) -> Meter {
        let history = self.history(now: now, calendar: calendar)
        let last = history.last
        func window(_ used: Double?, _ resets: Date?) -> LimitWindow? {
            guard let used, let resets else { return nil }
            return LimitWindow(utilization: used, resetsAt: resets)
        }
        let snapshot = last.map {
            UsageSnapshot(fiveHour: window($0.fiveHour, $0.fiveHourResetsAt), week: window($0.week, $0.weekResetsAt), fetchedAt: now)
        }
        return Meter(config: .default, snapshot: snapshot, history: history)
    }

    public static func history(now: Date, calendar: Calendar = .current) -> [Sample] {
        var rng = SplitMix(state: 7)
        let week: TimeInterval = 7 * 86400
        // Weekly windows reset on Tuesdays at 04:00, like the real one.
        var weekReset = calendar.nextDate(after: now, matching: DateComponents(hour: 4, weekday: 3), matchingPolicy: .nextTime)!
        // Last week, Anthropic reset everyone's usage early on the Thursday at 12:00.
        let earlyReset = weekReset.addingTimeInterval(-2 * week + 2 * 86400 + 8 * 3600)
        let start = now.addingTimeInterval(-35 * 86400)
        while weekReset.addingTimeInterval(-week) > start { weekReset.addTimeInterval(-week) }

        var samples: [Sample] = []
        var weekUsed = 0.0, fiveUsed = 0.0
        var fiveReset: Date?
        var day = Date.distantPast, dayPace = 1.0, busy = false
        var t = start
        while t <= now {
            if t >= weekReset { weekUsed = 0; weekReset.addTimeInterval(week) }
            if let r = fiveReset, t >= r { fiveReset = nil; fiveUsed = 0 }
            if t >= earlyReset && t < earlyReset.addingTimeInterval(120) { weekUsed = 0; fiveUsed = 0; fiveReset = nil }
            if !calendar.isDate(t, inSameDayAs: day) { day = t; dayPace = 0.35 + 1.1 * rng.next() }

            let c = calendar.dateComponents([.weekday, .hour, .minute], from: t)
            let minute = c.hour! * 60 + c.minute!
            let workday = (2...6).contains(c.weekday!)
            let awake = workday && (8 * 60 + 30 ..< 18 * 60 + 30).contains(minute)
            busy = workday && (9 * 60 ..< 17 * 60 + 30).contains(minute) && rng.next() < (busy ? 0.93 : 0.06)
            if busy {
                if fiveReset == nil { fiveReset = t.addingTimeInterval(5 * 3600) }
                let step = (0.2 + rng.next()) * 1.1 * dayPace
                fiveUsed += step
                weekUsed += step * 0.16
            }
            if awake || t.addingTimeInterval(120) > now {
                samples.append(Sample(at: t, fiveHour: fiveReset == nil ? nil : fiveUsed.rounded(), week: weekUsed.rounded(),
                                      fiveHourResetsAt: fiveReset, weekResetsAt: weekReset))
            }
            t.addTimeInterval(120)
        }
        return samples
    }
}

/// A small seeded generator, the same on every platform.
struct SplitMix {
    var state: UInt64

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(UInt64(1) << 53)
    }
}
