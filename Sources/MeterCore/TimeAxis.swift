import Foundation

/// Places moments along a chart's time axis. Time outside working hours can be squeezed to a
/// fraction of its width, so the working days take up most of the chart.
public struct TimeAxis: Sendable {
    /// The share of its true width each kind of time outside working hours gets: 1 draws it to scale.
    public struct Weights: Equatable, Sendable {
        /// Evenings, nights and early mornings around a working day.
        public var offHours: Double
        /// Whole days without working hours, such as weekends.
        public var daysOff: Double

        public init(offHours: Double, daysOff: Double) { self.offHours = offHours; self.daysOff = daysOff }
    }

    public static let toScale = Weights(offHours: 1, daysOff: 1)
    /// Leaves Mon–Fri 09:00–17:30 about three quarters of a week's width. Days off get less than
    /// nights: at the same share, Friday evening to Monday morning came out wider than a working day.
    public static let squeezed = Weights(offHours: 0.15, daysOff: 0.03)

    public let start: Date
    public let end: Date
    public let weights: Weights
    /// The working intervals between start and end.
    public let work: [DateInterval]
    /// The days off between start and end.
    public let daysOff: [DateInterval]
    let calendar: Calendar

    public init(from start: Date, to end: Date, schedule: WorkSchedule, weights: Weights = toScale,
                calendar: Calendar = .current) {
        self.start = start; self.end = max(start, end); self.weights = weights; self.calendar = calendar
        var work: [DateInterval] = []
        schedule.forEachWorkInterval(from: start, to: end, calendar) { work.append($0); return true }
        self.work = work
        var daysOff: [DateInterval] = []
        var day = calendar.startOfDay(for: start)
        while day < end, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            if schedule.workInterval(onDayOf: day, calendar) == nil {
                daysOff.append(DateInterval(start: max(day, start), end: min(next, end)))
            }
            day = next
        }
        self.daysOff = daysOff
    }

    /// Seconds from the start, with time outside working hours scaled by `weights`.
    public func x(_ t: Date) -> Double {
        let t = min(max(t, start), end)
        func seconds(in intervals: [DateInterval]) -> Double {
            intervals.reduce(0.0) { $0 + max(0, min($1.end, t).timeIntervalSince($1.start)) }
        }
        let working = seconds(in: work), off = seconds(in: daysOff)
        return working + weights.daysOff * off + weights.offHours * (t.timeIntervalSince(start) - working - off)
    }

    public var length: Double { x(end) }

    public var workBands: [ClosedRange<Double>] { work.map { x($0.start)...x($0.end) } }

    public struct Day: Equatable, Sendable {
        /// Local midnight.
        public var date: Date
        /// How much of the axis it covers.
        public var width: Double
        /// Where to label it: the middle of its working hours, or of the day if it has none.
        public var middle: Double
    }

    /// Each calendar day the axis covers, cut to the axis at either end.
    public var days: [Day] {
        var out: [Day] = []
        var day = calendar.startOfDay(for: start)
        while day < end, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            let from = max(day, start), to = min(next, end)
            let hours = work.first { $0.start >= day && $0.end <= next }
            let middle = hours.map { $0.start.addingTimeInterval($0.duration / 2) }
                ?? from.addingTimeInterval(to.timeIntervalSince(from) / 2)
            out.append(Day(date: day, width: x(to) - x(from), middle: x(middle)))
            day = next
        }
        return out
    }

    /// Where one day ends and the next begins.
    public var midnights: [Double] { days.dropFirst().map { x($0.date) } }

    /// Times worth labelling on an axis of one day: the working day's start, end and middle,
    /// then midnight, or every six hours on a day off. Any that would crowd one already
    /// chosen are left out, which with off-hours squeezed is usually midnight.
    public var clockTicks: [Date] {
        let candidates: [Date]
        if let w = work.first {
            let middle = calendar.dateInterval(of: .hour, for: w.start.addingTimeInterval(w.duration / 2))?.start
            candidates = [w.start, w.end, middle, start].compactMap { $0 }
        } else {
            candidates = stride(from: 0.0, to: end.timeIntervalSince(start), by: 6 * 3600).map { start.addingTimeInterval($0) }
        }
        var kept: [Date] = []
        for t in candidates where kept.allSatisfy({ abs(x(t) - x($0)) >= 0.16 * length }) {
            kept.append(t)
        }
        return kept.sorted()
    }

    /// Each whole hour from the start to the end.
    public var hourTicks: [Date] {
        guard var t = calendar.dateInterval(of: .hour, for: start)?.start else { return [] }
        if t < start { t.addTimeInterval(3600) }
        var out: [Date] = []
        while t <= end { out.append(t); t.addTimeInterval(3600) }
        return out
    }
}
