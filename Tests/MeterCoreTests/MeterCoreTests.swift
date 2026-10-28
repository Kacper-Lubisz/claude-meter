import Foundation
import Testing
@testable import MeterCore

let london: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/London")!
    return c
}()

/// Local London time. 2026-10-19 is a Monday.
func at(_ s: String) -> Date {
    let f = DateFormatter()
    f.calendar = london; f.timeZone = london.timeZone
    f.locale = Locale(identifier: "en_GB_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

let sched = WorkSchedule.default
let hour: TimeInterval = 3600

@Suite struct WorkScheduleTests {
    @Test func countsOnlyWeekdayHoursBefore1730() {
        // Fri 16:00 -> Mon 10:00: 1.5h on Friday, 1h on Monday, weekend ignored.
        #expect(sched.workingSeconds(from: at("2026-10-23 16:00"), to: at("2026-10-26 10:00"), calendar: london) == 2.5 * hour)
    }

    @Test func eveningAndEarlyMorningCountAsZero() {
        #expect(sched.workingSeconds(from: at("2026-10-21 17:30"), to: at("2026-10-22 09:00"), calendar: london) == 0)
    }

    @Test func fullWeekIs42AndAHalfHours() {
        #expect(sched.workingSeconds(from: at("2026-10-19 00:00"), to: at("2026-10-26 00:00"), calendar: london) == 42.5 * hour)
    }

    @Test func addingWorkingTimeSkipsTheWeekend() {
        let d = sched.date(addingWorkingSeconds: 2 * hour, to: at("2026-10-23 16:30"), before: at("2026-10-27 00:00"), calendar: london)
        #expect(d == at("2026-10-26 10:00"))
    }

    @Test func addingWorkingTimeStopsAtLimit() {
        #expect(sched.date(addingWorkingSeconds: 10 * hour, to: at("2026-10-23 16:30"), before: at("2026-10-26 12:00"), calendar: london) == nil)
    }

    @Test func handlesClockChange() {
        // UK clocks go back on Sun 25 Oct 2026; a weekday is still 8.5h.
        #expect(sched.workingSeconds(from: at("2026-10-26 00:00"), to: at("2026-10-27 00:00"), calendar: london) == 8.5 * hour)
    }
}

@Suite struct ForecastTests {
    @Test func weekOnTrack() {
        // Week window opened Mon 04:00 and resets next Mon 04:00. Wed 13:15 is 2 days + 4.25h of work = 21.25h.
        let f = Forecast.make(utilization: 25, resetsAt: at("2026-10-26 04:00"), windowLength: 7 * 86400,
                              now: at("2026-10-21 13:15"), schedule: sched, calendar: london)
        #expect(f.elapsedWork == 21.25 * hour)
        #expect(f.remainingWork == 21.25 * hour)
        #expect(f.elapsedFraction == 0.5)
        #expect(abs(f.projected - 50) < 1e-9)
        #expect(f.status == .ok)
        #expect(f.runsOutAt == nil)
    }

    @Test func weekOvershootsAndSaysWhen() {
        // 60% after 21.25h -> projected 120%; 40% more takes 14.17h of work -> Fri 10:25.
        let f = Forecast.make(utilization: 60, resetsAt: at("2026-10-26 04:00"), windowLength: 7 * 86400,
                              now: at("2026-10-21 13:15"), schedule: sched, calendar: london)
        #expect(abs(f.projected - 120) < 1e-9)
        #expect(f.status == .over)
        #expect(f.runsOutAt == at("2026-10-23 10:25"))
        #expect(abs(f.affordablePerHour! - 40 / 21.25) < 1e-9)
    }

    @Test func fiveHourWindowIgnoresTimeAfter1730() {
        // Window 14:00-19:00, now 16:00 at 40%: 2h elapsed, only 1.5h left before 17:30 -> 70%.
        let f = Forecast.make(utilization: 40, resetsAt: at("2026-10-22 19:00"), windowLength: 5 * hour,
                              now: at("2026-10-22 16:00"), schedule: sched, calendar: london)
        #expect(f.remainingWork == 1.5 * hour)
        #expect(abs(f.projected - 70) < 1e-9)
        #expect(f.status == .ok)
    }

    @Test func warnBand() {
        let f = Forecast.make(utilization: 46, resetsAt: at("2026-10-26 04:00"), windowLength: 7 * 86400,
                              now: at("2026-10-21 13:15"), schedule: sched, calendar: london)
        #expect(f.status == .warn) // projected 92%
    }

    @Test func noElapsedWorkUsesFloor() {
        // Saturday use: zero working time, rate measured over 15 minutes, but nothing left before reset either.
        let f = Forecast.make(utilization: 10, resetsAt: at("2026-10-24 15:00"), windowLength: 5 * hour,
                              now: at("2026-10-24 12:00"), schedule: sched, calendar: london)
        #expect(f.burnPerHour == 40)
        #expect(f.projected == 10)
        #expect(f.elapsedFraction == nil)
    }

    @Test func alreadyAtLimit() {
        let now = at("2026-10-22 11:00")
        let f = Forecast.make(utilization: 100, resetsAt: at("2026-10-22 13:00"), windowLength: 5 * hour,
                              now: now, schedule: sched, calendar: london)
        #expect(f.status == .over)
        #expect(f.runsOutAt == now)
    }
}

@Suite struct ParsingTests {
    @Test func parsesRealResponseShape() throws {
        let json = """
        {"five_hour":{"utilization":3.0,"resets_at":"2026-10-22T13:00:00.102594+00:00","limit_dollars":null},
         "seven_day":{"utilization":2.0,"resets_at":"2026-10-27T03:00:00.102614+00:00"},
         "seven_day_opus":null,"extra_usage":{"is_enabled":false}}
        """
        let s = try UsageClient.parse(Data(json.utf8), fetchedAt: Date())
        #expect(s.fiveHour?.utilization == 3)
        #expect(s.week?.resetsAt == UsageClient.parseDate("2026-10-27T03:00:00Z"))
    }

    @Test func missingWindowIsNil() throws {
        let s = try UsageClient.parse(Data(#"{"five_hour":null,"seven_day":{"utilization":5,"resets_at":null}}"#.utf8), fetchedAt: Date())
        #expect(s.fiveHour == nil && s.week == nil)
    }

    @Test func historyDropsOldSamples() {
        let now = Date()
        let old = Sample(at: now.addingTimeInterval(-43 * 86400), fiveHour: 1, week: 1)
        let recent = Sample(at: now.addingTimeInterval(-41 * 86400), fiveHour: 1, week: 1)
        #expect(History.pruned([old, recent], now: now) == [recent])
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let s = UsageSnapshot(fiveHour: LimitWindow(utilization: 12, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
                              week: nil, fetchedAt: Date(timeIntervalSince1970: 1_799_990_000))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        #expect(try dec.decode(UsageSnapshot.self, from: enc.encode(s)) == s)
    }
}
