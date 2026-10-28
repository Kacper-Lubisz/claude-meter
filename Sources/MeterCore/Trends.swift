import Foundation

/// A usage percentage at a moment.
public struct Reading: Codable, Equatable, Sendable {
    public var at: Date
    public var used: Double
    public init(at: Date, used: Double) { self.at = at; self.used = used }
}

/// Usage wiped before its window was due to reset. Anthropic occasionally resets everyone's
/// limits (after an outage, say), and the usage endpoint just shows usage back near 0.
public struct EarlyReset: Equatable, Sendable {
    public var at: Date
    /// The usage it wiped.
    public var givenBack: Double
}

/// One rate-limit window as recorded in the history.
public struct UsageWindow: Equatable, Sendable {
    public var kind: LimitKind
    public var start: Date
    /// When it resets, or did. Unknown for windows recorded before reset times were saved.
    public var resetsAt: Date?
    public var readings: [Reading]
    /// Set when it opened because the window before was reset early with a new reset time.
    public var openedEarly: EarlyReset?

    /// Usage so far at each reading, from 0 at the opening when that's known. After an early
    /// reset it carries on from where it was rather than dropping back, so it's what was used,
    /// not what the limit showed.
    public var progress: [Reading] { tally().progress }

    /// Early resets during the window, including the one it opened with.
    public var earlyResets: [EarlyReset] { (openedEarly.map { [$0] } ?? []) + tally().resets }

    /// By the end, or so far for the open window.
    public var used: Double { progress.last?.used ?? 0 }

    /// The last moment known to belong to it.
    public var end: Date { resetsAt ?? readings.last?.at ?? start }

    public func isOpen(at now: Date) -> Bool {
        if let resetsAt { return resetsAt > now }
        return now.timeIntervalSince(start) < kind.length
    }

    /// Usage `offset` seconds after the window opened, as of the last reading by then. Like the
    /// days, use between two readings counts at the later one, so a gap while the meter wasn't
    /// running doesn't spread use over hours nobody worked.
    public func used(after offset: TimeInterval) -> Double? {
        let t = start.addingTimeInterval(max(0, offset))
        return progress.last { $0.at <= t }?.used
    }

    /// Readings two windows apart differ in reset time by at least the window's length,
    /// but one window's reported reset time can wobble a little between polls.
    static let resetTolerance: TimeInterval = 3600

    /// Usage only rises within a window, so a fall of more than this (readings are whole
    /// percentages) means it was reset early.
    static let earlyResetDrop = 1.5

    func tally() -> (progress: [Reading], resets: [EarlyReset]) {
        var progress = resetsAt == nil ? [] : [Reading(at: start, used: 0)]
        var resets: [EarlyReset] = []
        var level = 0.0, total = 0.0
        for r in readings {
            if resetsAt != nil, r.used < level - Self.earlyResetDrop {
                resets.append(EarlyReset(at: r.at, givenBack: level))
                level = 0
            }
            if r.used > level { total += r.used - level; level = r.used }
            progress.append(Reading(at: r.at, used: total))
        }
        return (progress, resets)
    }

    func admits(_ r: Reading, resetsAt resets: Date?) -> Bool {
        if let mine = resetsAt {
            if r.at >= mine { return false }
            if let resets, abs(resets.timeIntervalSince(mine)) > Self.resetTolerance { return false }
            return true
        }
        // Without reset times, usage only ever rises within a window, and a gap longer
        // than the window means it must have reset.
        guard let last = readings.last else { return true }
        return r.used >= last.used - 0.5 && r.at.timeIntervalSince(last.at) < kind.length
    }
}

/// Weekly-limit usage on one calendar day.
public struct DayUsage: Equatable, Sendable {
    /// Local midnight.
    public var day: Date
    /// Each rise in weekly usage that day.
    public var use: [Reading]
    /// False when the meter wasn't running that day, so 0 means "unknown", not "unused".
    public var hasReadings: Bool

    public var used: Double { use.reduce(0) { $0 + $1.used } }

    public func used(by t: Date) -> Double {
        use.reduce(0) { $1.at <= t ? $0 + $1.used : $0 }
    }

    /// Running total through the day.
    public var cumulative: [Reading] {
        var total = 0.0
        return use.map { total += $0.used; return Reading(at: $0.at, used: total) }
    }
}

/// How one window compares with another at the same point in each.
public struct WindowComparison: Equatable, Sendable {
    public var subject: UsageWindow
    public var baseline: UsageWindow
    /// How far into the subject the comparison is made: up to now while it's open, else all of it.
    public var offset: TimeInterval
    public var isOpen: Bool

    /// The baseline's usage at the same point; nil if its readings don't reach back that far.
    public var baselineUsed: Double? { isOpen ? baseline.used(after: offset) : baseline.used }
    public var delta: Double? { baselineUsed.map { subject.used - $0 } }
}

/// The history arranged for comparing days, weeks and 5-hour windows.
public struct Trends: Equatable, Sendable {
    /// Oldest first.
    public var fiveHourWindows: [UsageWindow]
    public var weeks: [UsageWindow]
    /// Each rise in weekly usage between readings: how much of the week's limit was used in between.
    /// A rise is counted when it's seen, so use while the meter wasn't running lands on its next reading.
    public var weekUse: [Reading]
    var readingTimes: [Date]

    public static let empty = Trends([])

    public init(_ samples: [Sample]) {
        let sorted = samples.sorted { $0.at < $1.at }
        fiveHourWindows = Self.windows(.fiveHour, in: sorted)
        weeks = Self.windows(.week, in: sorted)
        weekUse = Self.weekUse(weeks)
        readingTimes = sorted.map(\.at)
    }

    public func windows(_ kind: LimitKind) -> [UsageWindow] { kind == .fiveHour ? fiveHourWindows : weeks }

    static func windows(_ kind: LimitKind, in samples: [Sample]) -> [UsageWindow] {
        var out: [UsageWindow] = []
        for s in samples {
            guard let used = s.used(kind) else { continue }
            let r = Reading(at: s.at, used: used)
            let resets = s.resetsAt(kind)
            if var w = out.last, w.admits(r, resetsAt: resets) {
                if w.resetsAt == nil, let resets {
                    w.resetsAt = resets
                    w.start = resets.addingTimeInterval(-kind.length)
                }
                w.readings.append(r)
                out[out.count - 1] = w
            } else {
                var w = UsageWindow(kind: kind, start: resets?.addingTimeInterval(-kind.length) ?? s.at,
                                    resetsAt: resets, readings: [r])
                // A new reset time before the old one came due: the window before was reset early.
                if var prev = out.last, let due = prev.resetsAt, r.at < due, let last = prev.readings.last {
                    let cut = min(max(w.start, last.at), r.at)
                    prev.resetsAt = cut
                    out[out.count - 1] = prev
                    w.start = cut
                    if due.timeIntervalSince(cut) > UsageWindow.resetTolerance {
                        w.openedEarly = EarlyReset(at: cut, givenBack: last.used)
                    }
                }
                out.append(w)
            }
        }
        return out
    }

    static func weekUse(_ weeks: [UsageWindow]) -> [Reading] {
        // Progress starts from 0 when the opening is known. Otherwise it starts at the first
        // reading, whose use happened at some unknown time and so isn't counted.
        weeks.flatMap { w -> [Reading] in
            let p = w.progress
            return zip(p, p.dropFirst()).compactMap { a, b in
                b.used > a.used ? Reading(at: b.at, used: b.used - a.used) : nil
            }
        }
    }

    /// How much of the weekly limit was used while a window was open.
    public func weekUse(during w: UsageWindow, now: Date) -> Double {
        let end = min(w.end, now)
        return weekUse.reduce(0) { $1.at > w.start && $1.at <= end ? $0 + $1.used : $0 }
    }

    // MARK: Days

    /// The `count` days up to and including today, oldest first.
    public func days(endingAt now: Date, count: Int, calendar: Calendar = .current) -> [DayUsage] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { back -> DayUsage? in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return DayUsage(day: day, use: weekUse.filter { $0.at >= day && $0.at < next },
                            hasReadings: readingTimes.contains { $0 >= day && $0 < next })
        }
    }

    /// The same clock time as `t` on another day.
    public static func sameTime(as t: Date, on day: Date, calendar: Calendar = .current) -> Date {
        let c = calendar.dateComponents([.hour, .minute, .second], from: t)
        return calendar.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0, of: day)
            ?? day.addingTimeInterval(t.timeIntervalSince(calendar.startOfDay(for: t)))
    }

    /// What today is compared with unless another day is picked: the last working day before it.
    public static func defaultBaseline(in days: [DayUsage], schedule: WorkSchedule,
                                       calendar: Calendar = .current) -> DayUsage? {
        let earlier = days.dropLast()
        return earlier.last { schedule.workdays.contains(schedule.isoWeekday($0.day, calendar)) } ?? earlier.last
    }

    // MARK: Windows

    /// The open window, or the latest one if none is open.
    public func latest(_ kind: LimitKind) -> UsageWindow? { windows(kind).last }

    /// The window before `w`.
    public func window(before w: UsageWindow) -> UsageWindow? {
        let all = windows(w.kind)
        guard let i = all.firstIndex(of: w), i > 0 else { return nil }
        return all[i - 1]
    }

    /// `subject` (by default the latest window) against `baseline` (by default the one before
    /// it), at the same point in each.
    public func compare(_ kind: LimitKind, now: Date, subject: UsageWindow? = nil,
                        baseline: UsageWindow? = nil) -> WindowComparison? {
        guard let subject = subject ?? latest(kind),
              let baseline = baseline ?? window(before: subject) else { return nil }
        let open = subject.isOpen(at: now)
        return WindowComparison(subject: subject, baseline: baseline,
                                offset: open ? now.timeIntervalSince(subject.start) : kind.length, isOpen: open)
    }
}
