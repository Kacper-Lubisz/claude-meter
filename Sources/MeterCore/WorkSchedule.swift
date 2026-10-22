import Foundation

/// The hours that count when measuring burn rate. Time outside them
/// (weekends, evenings, early mornings) is treated as if it doesn't exist.
public struct WorkSchedule: Codable, Equatable, Sendable {
    /// ISO weekdays: 1 = Monday ... 7 = Sunday.
    public var workdays: [Int]
    /// "HH:mm", local time.
    public var dayStart: String
    public var dayEnd: String

    public static let `default` = WorkSchedule(workdays: [1, 2, 3, 4, 5], dayStart: "09:00", dayEnd: "17:30")

    public init(workdays: [Int], dayStart: String, dayEnd: String) {
        self.workdays = workdays.sorted()
        self.dayStart = dayStart
        self.dayEnd = dayEnd
    }

    var startMinutes: Int { Self.minutes(dayStart) ?? 9 * 60 }
    var endMinutes: Int { Self.minutes(dayEnd) ?? (17 * 60 + 30) }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    /// ISO weekday (Mon = 1) for a date.
    func isoWeekday(_ date: Date, _ cal: Calendar) -> Int {
        let w = cal.component(.weekday, from: date) // Sun = 1
        return w == 1 ? 7 : w - 1
    }

    /// The working interval on the day containing `date`, or nil on a day off.
    func workInterval(onDayOf date: Date, _ cal: Calendar) -> DateInterval? {
        guard workdays.contains(isoWeekday(date, cal)), endMinutes > startMinutes else { return nil }
        let midnight = cal.startOfDay(for: date)
        guard let s = cal.date(byAdding: .minute, value: startMinutes, to: midnight),
              let e = cal.date(byAdding: .minute, value: endMinutes, to: midnight) else { return nil }
        return DateInterval(start: s, end: e)
    }

    /// Calls `body` with each working interval overlapping [from, to), clipped to that range.
    func forEachWorkInterval(from: Date, to: Date, _ cal: Calendar, _ body: (DateInterval) -> Bool) {
        guard to > from else { return }
        var day = cal.startOfDay(for: from)
        while day < to {
            if let work = workInterval(onDayOf: day, cal) {
                let s = max(work.start, from), e = min(work.end, to)
                if e > s, !body(DateInterval(start: s, end: e)) { return }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return }
            day = next
        }
    }

    /// Working seconds between two instants.
    public func workingSeconds(from: Date, to: Date, calendar cal: Calendar = .current) -> TimeInterval {
        var total: TimeInterval = 0
        forEachWorkInterval(from: from, to: to, cal) { total += $0.duration; return true }
        return total
    }

    /// The instant at which `seconds` of working time will have passed after `from`,
    /// as long as that happens before `limit`.
    public func date(addingWorkingSeconds seconds: TimeInterval, to from: Date, before limit: Date,
                     calendar cal: Calendar = .current) -> Date? {
        var left = seconds
        var result: Date?
        forEachWorkInterval(from: from, to: limit, cal) { iv in
            if iv.duration >= left { result = iv.start.addingTimeInterval(left); return false }
            left -= iv.duration
            return true
        }
        return result
    }

    public func isWorking(at date: Date, calendar cal: Calendar = .current) -> Bool {
        workInterval(onDayOf: date, cal)?.contains(date) ?? false
    }
}
