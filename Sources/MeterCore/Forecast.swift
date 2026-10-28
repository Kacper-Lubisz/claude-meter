import Foundation

public enum PaceStatus: Int, Comparable, Sendable {
    case ok, warn, over
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Where a rate-limit window is heading, measured in working time only.
public struct Forecast: Equatable, Sendable {
    public var utilization: Double          // percent used now, 0...100+
    public var windowStart: Date
    public var resetsAt: Date
    public var elapsedWork: TimeInterval     // working seconds since the window opened
    public var remainingWork: TimeInterval   // working seconds until it resets
    public var burnPerHour: Double           // percent per working hour so far
    public var projected: Double             // percent expected at reset
    public var runsOutAt: Date?              // when 100% is reached, if before reset
    public var affordablePerHour: Double?    // pace that lands exactly on 100% at reset
    public var status: PaceStatus

    /// Below this much elapsed working time the rate is too noisy to trust,
    /// so it's measured as if this much had passed.
    public static let minimumElapsed: TimeInterval = 15 * 60
    public static let warnThreshold = 90.0

    /// How far through the window's working time we are, 0...1; nil if it has none.
    public var elapsedFraction: Double? {
        let total = elapsedWork + remainingWork
        return total > 0 ? elapsedWork / total : nil
    }

    public static func make(utilization: Double, resetsAt: Date, windowLength: TimeInterval,
                            now: Date, schedule: WorkSchedule, calendar: Calendar = .current) -> Forecast {
        let start = resetsAt.addingTimeInterval(-windowLength)
        let elapsed = schedule.workingSeconds(from: start, to: now, calendar: calendar)
        let remaining = schedule.workingSeconds(from: now, to: resetsAt, calendar: calendar)
        let ratePerSecond = utilization / max(elapsed, minimumElapsed)
        let projected = utilization + ratePerSecond * remaining

        var runsOut: Date?
        if utilization >= 100 {
            runsOut = now
        } else if projected > 100, ratePerSecond > 0 {
            runsOut = schedule.date(addingWorkingSeconds: (100 - utilization) / ratePerSecond,
                                    to: now, before: resetsAt, calendar: calendar)
        }

        let status: PaceStatus = utilization >= 100 || projected > 100 ? .over
            : projected >= warnThreshold ? .warn : .ok

        return Forecast(
            utilization: utilization, windowStart: start, resetsAt: resetsAt,
            elapsedWork: elapsed, remainingWork: remaining,
            burnPerHour: ratePerSecond * 3600, projected: projected, runsOutAt: runsOut,
            affordablePerHour: remaining > 0 ? max(0, 100 - utilization) / remaining * 3600 : nil,
            status: status)
    }
}
