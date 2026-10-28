import Foundation
import Testing
@testable import MeterCore

/// A reading with reset times, all in London time.
func reading(_ t: String, five: Double? = nil, fiveResets: String? = nil, week: Double? = nil, weekResets: String? = nil) -> Sample {
    Sample(at: at(t), fiveHour: five, week: week,
           fiveHourResetsAt: fiveResets.map(at), weekResetsAt: weekResets.map(at))
}

@Suite struct WindowTests {
    @Test func splitsWindowsByResetTime() {
        // The second window's first reading (8%) is higher than the first's last (5%), so only
        // the reset time can tell them apart. Reported reset times wobble by a second.
        let t = Trends([
            reading("2026-10-22 09:10", five: 2, fiveResets: "2026-10-22 14:00"),
            Sample(at: at("2026-10-22 13:50"), fiveHour: 5, week: nil, fiveHourResetsAt: at("2026-10-22 14:00").addingTimeInterval(1)),
            reading("2026-10-22 14:40", five: 8, fiveResets: "2026-10-22 19:30"),
        ])
        #expect(t.fiveHourWindows.count == 2)
        #expect(t.fiveHourWindows[0].start == at("2026-10-22 09:00"))
        #expect(t.fiveHourWindows[0].used == 5)
        #expect(t.fiveHourWindows[1].start == at("2026-10-22 14:30"))
    }

    @Test func oldReadingsSplitWhereUsageDropsOrAfterALongGap() {
        let t = Trends([
            reading("2026-10-22 09:10", five: 10), reading("2026-10-22 10:00", five: 20),
            reading("2026-10-22 14:30", five: 3),                                         // dropped: new window
            reading("2026-10-23 09:00", five: 7),                                         // 18h later: new window
        ])
        #expect(t.fiveHourWindows.map(\.used) == [20, 3, 7])
        #expect(t.fiveHourWindows[0].resetsAt == nil)
        #expect(t.fiveHourWindows[0].start == at("2026-10-22 09:10"))
    }

    @Test func oldWindowAdoptsAResetTimeOnceOneIsRecorded() {
        let t = Trends([reading("2026-10-15 09:10", week: 2),
                        reading("2026-10-15 09:12", week: 3, weekResets: "2026-10-20 04:00")])
        #expect(t.weeks.count == 1)
        #expect(t.weeks[0].start == at("2026-10-13 04:00"))
    }

    @Test func holdsEachReadingUntilTheNext() {
        let w = Trends([reading("2026-10-22 10:00", five: 20, fiveResets: "2026-10-22 14:00"),
                        reading("2026-10-22 11:00", five: 40, fiveResets: "2026-10-22 14:00")]).fiveHourWindows[0]
        #expect(w.used(after: 0.5 * hour) == 0)    // opened 09:00 at 0
        #expect(w.used(after: 1.5 * hour) == 20)
        #expect(w.used(after: 4 * hour) == 40)
    }

    @Test func startsAtTheFirstReadingWhenTheOpeningIsUnknown() {
        let w = Trends([reading("2026-10-22 10:00", five: 20), reading("2026-10-22 11:00", five: 40)]).fiveHourWindows[0]
        #expect(w.used(after: 0) == 20)
        #expect(w.used(after: 0.5 * hour) == 20)
        #expect(w.used(after: -hour) == 20)
    }

    @Test func comparesAtTheSamePointInEachWindow() {
        // Last week reached 20% two days in and finished at 60%. This week is 25% two days in.
        let t = Trends([
            reading("2026-10-08 04:00", week: 20, weekResets: "2026-10-13 04:00"),
            reading("2026-10-12 12:00", week: 60, weekResets: "2026-10-13 04:00"),
            reading("2026-10-15 04:00", week: 25, weekResets: "2026-10-20 04:00"),
        ])
        let open = try! #require(t.compare(.week, now: at("2026-10-15 04:00")))
        #expect(open.isOpen)
        #expect(open.offset == 2 * 86400)
        #expect(open.baselineUsed == 20)
        #expect(open.delta == 5)

        // Once it's over, whole windows are compared.
        let closed = try! #require(t.compare(.week, now: at("2026-10-21 09:00")))
        #expect(!closed.isOpen)
        #expect(closed.baselineUsed == 60)
        #expect(closed.delta == -35)
    }

    @Test func firstWindowHasNothingToCompareWith() {
        #expect(Trends([reading("2026-10-22 10:00", five: 20, fiveResets: "2026-10-22 14:00")])
            .compare(.fiveHour, now: at("2026-10-22 10:00")) == nil)
    }
}

@Suite struct EarlyResetTests {
    /// Week of 6 Oct (due to reset Tue 13 Oct 04:00): 40% by Wednesday, then usage reset on Thursday.
    let trends = Trends([
        reading("2026-10-07 12:00", week: 40, weekResets: "2026-10-13 04:00"),
        reading("2026-10-08 12:00", week: 0, weekResets: "2026-10-13 04:00"),
        reading("2026-10-08 15:00", week: 5, weekResets: "2026-10-13 04:00"),
    ])

    @Test func usageFallingBeforeTheResetTimeIsAnEarlyReset() {
        #expect(trends.weeks.count == 1)
        let w = trends.weeks[0]
        #expect(w.earlyResets == [EarlyReset(at: at("2026-10-08 12:00"), givenBack: 40)])
        // What was used carries on past the reset rather than starting again.
        #expect(w.progress.map(\.used) == [0, 40, 40, 45])
        #expect(w.used == 45)
        #expect(trends.weekUse.map(\.used) == [40, 5])
    }

    @Test func aOnePointDipIsNotAReset() {
        let w = Trends([reading("2026-10-07 12:00", week: 40, weekResets: "2026-10-13 04:00"),
                        reading("2026-10-07 12:02", week: 39, weekResets: "2026-10-13 04:00")]).weeks[0]
        #expect(w.earlyResets.isEmpty)
        #expect(w.used == 40)
    }

    @Test func aNewResetTimeBeforeTheOldOneEndsTheWindowEarly() {
        // Reset on Thu 8 Oct at 12:00, with a fresh week from then.
        let t = Trends([
            reading("2026-10-07 12:00", week: 40, weekResets: "2026-10-13 04:00"),
            reading("2026-10-08 12:02", week: 1, weekResets: "2026-10-15 12:00"),
        ])
        #expect(t.weeks.count == 2)
        #expect(t.weeks[0].resetsAt == at("2026-10-08 12:00"))
        #expect(!t.weeks[0].isOpen(at: at("2026-10-08 13:00")))
        #expect(t.weeks[1].start == at("2026-10-08 12:00"))
        #expect(t.weeks[1].earlyResets == [EarlyReset(at: at("2026-10-08 12:00"), givenBack: 40)])
        #expect(t.weekUse.map(\.used) == [40, 1])
    }

    @Test func theReportListsIt() {
        let now = at("2026-10-08 15:00")
        let meter = Meter(config: .default, snapshot: UsageSnapshot(
            fiveHour: nil, week: LimitWindow(utilization: 5, resetsAt: at("2026-10-13 04:00")), fetchedAt: now),
            history: [reading("2026-10-07 12:00", week: 40, weekResets: "2026-10-13 04:00"),
                      reading("2026-10-08 12:00", week: 0, weekResets: "2026-10-13 04:00"),
                      reading("2026-10-08 15:00", week: 5, weekResets: "2026-10-13 04:00")])
        let report = Report(meter: meter, now: now, calendar: london)
        #expect(report.sections[1].rows.contains { $0.label == "Reset early" && $0.value == "12:00 · 40% back" })
        #expect(report.sections[3].rows.contains { $0.label == "From Tue 6 Oct (open) ↺" && $0.value == "45%" })
    }
}

@Suite struct TimeAxisTests {
    /// Tue 6 Oct 04:00 to Tue 13 Oct 04:00: five working days of 8.5 hours.
    let from = at("2026-10-06 04:00"), to = at("2026-10-13 04:00")
    let quarter = TimeAxis.Weights(offHours: 0.25, daysOff: 0.25)

    @Test func toScaleByDefault() {
        let a = TimeAxis(from: from, to: to, schedule: sched, calendar: london)
        #expect(a.length == 7 * 86400)
        #expect(a.x(at("2026-10-07 04:00")) == 86400)
        #expect(a.x(at("2026-10-01 00:00")) == 0)
    }

    @Test func squeezesTimeOutsideWorkingHours() {
        let a = TimeAxis(from: from, to: to, schedule: sched, weights: quarter, calendar: london)
        #expect(a.length == (42.5 + 0.25 * (168 - 42.5)) * hour)
        // Tue 04:00–09:00 is five hours off, then the working day counts in full.
        #expect(a.x(at("2026-10-06 09:00")) == 1.25 * hour)
        #expect(a.x(at("2026-10-06 17:30")) == 9.75 * hour)
        #expect(a.workBands.count == 5)
        #expect(a.workBands[0] == 1.25 * hour...9.75 * hour)
    }

    @Test func squeezesDaysOffFurtherThanNights() {
        let a = TimeAxis(from: from, to: to, schedule: sched, weights: .init(offHours: 0.25, daysOff: 0.125), calendar: london)
        #expect(a.daysOff.map(\.start) == [at("2026-10-10 00:00"), at("2026-10-11 00:00")])
        // Fri 17:30 to Mon 09:00: Friday evening and Monday morning as off-hours, the weekend as days off.
        #expect(a.x(at("2026-10-12 09:00")) - a.x(at("2026-10-09 17:30")) == (15.5 * 0.25 + 48 * 0.125) * hour)
        #expect(a.x(at("2026-10-09 09:00")) - a.x(at("2026-10-08 17:30")) == 15.5 * 0.25 * hour)
    }

    @Test func labelsEachDayInTheMiddleOfItsWorkingHours() {
        let a = TimeAxis(from: from, to: to, schedule: sched, weights: quarter, calendar: london)
        #expect(a.days.count == 8)   // Tue to Mon, then the start of the next Tuesday
        #expect(a.days[0].middle == a.x(at("2026-10-06 13:15")))
        #expect(a.days[4].middle == a.x(at("2026-10-10 12:00")))   // Saturday, which has no working hours
        #expect(a.days[7].width == 0.25 * 4 * hour)
        #expect(a.midnights.first == a.x(at("2026-10-07 00:00")))
    }

    @Test func ticksForADayAndForFiveHours() {
        let day = TimeAxis(from: at("2026-10-07 00:00"), to: at("2026-10-08 00:00"), schedule: sched, weights: quarter, calendar: london)
        #expect(day.clockTicks == ["00:00", "09:00", "13:00", "17:30"].map { at("2026-10-07 \($0)") })
        let saturday = TimeAxis(from: at("2026-10-10 00:00"), to: at("2026-10-11 00:00"), schedule: sched, calendar: london)
        #expect(saturday.clockTicks == ["00:00", "06:00", "12:00", "18:00"].map { at("2026-10-10 \($0)") })
        let five = TimeAxis(from: at("2026-10-07 09:40"), to: at("2026-10-07 14:40"), schedule: sched, calendar: london)
        #expect(five.hourTicks == (10...14).map { at("2026-10-07 \($0):00") })
    }
}

@Suite struct DayTests {
    /// Week of 20 Oct: 10% by Mon 12:00 (counted from the opening), 15% Mon 16:00,
    /// 22% Wed 10:00 (nothing recorded Tue), then a reset and 2% on Tue 27.
    let trends = Trends([
        reading("2026-10-19 12:00", week: 10, weekResets: "2026-10-20 04:00"),
        reading("2026-10-19 16:00", week: 15, weekResets: "2026-10-20 04:00"),
        reading("2026-10-21 10:00", week: 22, weekResets: "2026-10-27 04:00"),
        reading("2026-10-21 11:00", week: 22, weekResets: "2026-10-27 04:00"),
        reading("2026-10-27 09:00", week: 2, weekResets: "2026-11-03 04:00"),
    ])

    @Test func weeklyUseCountsEachRiseAndStartsAgainAfterAReset() {
        // The 20 Oct window opened at 0, so its first reading counts in full.
        #expect(trends.weekUse.map(\.used) == [10, 5, 22, 2])
    }

    @Test func totalsPerDayAndMarksDaysWithoutReadings() {
        let days = trends.days(endingAt: at("2026-10-21 18:00"), count: 3, calendar: london)
        #expect(days.map(\.day) == [at("2026-10-19 00:00"), at("2026-10-20 00:00"), at("2026-10-21 00:00")])
        #expect(days.map(\.used) == [15, 0, 22])
        #expect(days.map(\.hasReadings) == [true, false, true])
        #expect(days[0].used(by: at("2026-10-19 13:00")) == 10)
        #expect(days[0].cumulative.map(\.used) == [10, 15])
    }

    @Test func comparesTodayWithTheLastWorkingDay() {
        // On a Monday that's Friday, not Sunday.
        let days = trends.days(endingAt: at("2026-10-26 10:00"), count: 7, calendar: london)
        #expect(Trends.defaultBaseline(in: days, schedule: sched, calendar: london)?.day == at("2026-10-23 00:00"))
    }

    @Test func sameClockTimeAcrossTheClockChange() {
        // Mon 26 Oct is GMT, Fri 23 Oct BST: 15:10 still lines up with 15:10.
        #expect(Trends.sameTime(as: at("2026-10-26 15:10"), on: at("2026-10-23 00:00"), calendar: london) == at("2026-10-23 15:10"))
    }

    @Test func weeklyUseWhileAFiveHourWindowWasOpen() {
        let t = Trends([
            reading("2026-10-22 08:00", five: 30, fiveResets: "2026-10-22 08:30", week: 10, weekResets: "2026-10-27 04:00"),
            reading("2026-10-22 09:10", five: 5, fiveResets: "2026-10-22 14:00", week: 12, weekResets: "2026-10-27 04:00"),
            reading("2026-10-22 11:00", five: 30, fiveResets: "2026-10-22 14:00", week: 16, weekResets: "2026-10-27 04:00"),
        ])
        #expect(t.weekUse(during: t.fiveHourWindows[1], now: at("2026-10-22 12:00")) == 6)
    }
}

@Suite struct PersistenceTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("claude-meter-tests-\(UUID().uuidString)")
    }

    @Test func appendsAndReloadsReadings() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = reading("2026-10-22 09:00", five: 1, fiveResets: "2026-10-22 14:00", week: 2, weekResets: "2026-10-27 04:00")
        let b = reading("2026-10-22 09:02", five: 2, week: 2)
        History.append(a, in: dir)
        History.append(b, in: dir)
        #expect(History.load(from: dir) == [a, b])
    }

    @Test func skipsALineCutShort() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = reading("2026-10-22 09:00", five: 1, week: 2)
        History.append(a, in: dir)
        let h = try FileHandle(forWritingTo: History.url(in: dir))
        try h.seekToEnd(); try h.write(contentsOf: Data(#"{"at":"2026-10-22T09:"#.utf8)); try h.close()
        #expect(History.load(from: dir) == [a])
    }

    @Test func movesTheOldHistoryFileToTheNewFormat() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = #"[{"at":"2026-10-22T09:37:07Z","week":2,"fiveHour":3},{"at":"2026-10-22T09:39:07Z","week":2,"fiveHour":4}]"#
        try Data(old.utf8).write(to: History.legacyURL(in: dir))
        let loaded = History.load(from: dir)
        #expect(loaded.map(\.fiveHour) == [3, 4])
        #expect(!FileManager.default.fileExists(atPath: History.legacyURL(in: dir).path))
        #expect(History.load(from: dir) == loaded)
    }

    @Test func mergesTheOldFileWhenBothExist() throws {
        // An old build still running rewrote history.json after a new build had converted it.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        History.append(reading("2026-10-22 09:37", five: 3, week: 2), in: dir)
        let old = #"[{"at":"2026-10-22T08:37:00Z","week":2,"fiveHour":3},{"at":"2026-10-22T08:39:00Z","week":2,"fiveHour":4}]"#
        try Data(old.utf8).write(to: History.legacyURL(in: dir))
        #expect(History.load(from: dir).map(\.fiveHour) == [3, 4])
        #expect(!FileManager.default.fileExists(atPath: History.legacyURL(in: dir).path))
    }

    @Test func rateLimitBacksOffAcrossRestarts() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = at("2026-10-22 10:00")
        var m = Meter.load(config: .default, from: dir, now: now)
        #expect(m.canFetch(now: now))
        m.record(.rateLimited(retryAfter: nil), at: now)

        let reloaded = Meter.load(config: .default, from: dir, now: now)
        #expect(reloaded.status.error == .rateLimited(retryAfter: nil))
        #expect(!reloaded.canFetch(now: now.addingTimeInterval(4 * 60)))
        #expect(reloaded.canFetch(now: now.addingTimeInterval(5 * 60)))
    }

    @Test func successClearsTheErrorAndIsSaved() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = at("2026-10-22 10:00")
        var m = Meter.load(config: .default, from: dir, now: now)
        m.record(.network("offline"), at: now)
        #expect(!m.canFetch(now: now.addingTimeInterval(30), minInterval: 60))
        m.record(UsageSnapshot(fiveHour: LimitWindow(utilization: 12, resetsAt: at("2026-10-22 14:00")), week: nil,
                               fetchedAt: now.addingTimeInterval(120)))

        let reloaded = Meter.load(config: .default, from: dir, now: now.addingTimeInterval(120))
        #expect(reloaded.status.error == nil)
        #expect(reloaded.snapshot?.fiveHour?.utilization == 12)
        #expect(reloaded.history.last?.fiveHourResetsAt == at("2026-10-22 14:00"))
        #expect(reloaded.trends.fiveHourWindows.count == 1)
    }
}

@Suite struct CredentialsTests {
    let now = at("2026-10-22 10:00")

    @Test func readsTheTokenFromClaudeCodesCredentialsFile() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"r","expiresAt":1893456000000}}"#
        #expect(try Credentials.accessToken(from: Data(json.utf8), now: now) == "sk-ant-oat-x")
    }

    @Test func reportsAnExpiredLogin() {
        let json = #"{"claudeAiOauth":{"accessToken":"x","expiresAt":1000}}"#
        #expect(throws: UsageError.loginExpired) { try Credentials.accessToken(from: Data(json.utf8), now: now) }
    }

    @Test func reportsAMissingLogin() {
        #expect(throws: UsageError.noLogin) { try Credentials.accessToken(from: Data("{}".utf8), now: now) }
    }
}

@Suite struct ReportTests {
    @Test func demoDataFillsEverySection() throws {
        let now = SampleData.now(calendar: london, from: at("2026-10-24 12:00"))
        #expect(now == at("2026-10-23 15:10"))   // a Saturday falls back to Friday afternoon
        let meter = SampleData.meter(now: now, calendar: london)
        #expect(meter.trends.weeks.count >= 5)
        #expect(meter.trends.latest(.fiveHour)?.isOpen(at: now) == true)

        let report = Report(meter: meter, now: now, calendar: london)
        #expect(report.sections.map(\.title) == ["5-hour window", "Week", "Days", "Weeks", "5-hour windows"])
        #expect(report.items.map(\.label) == ["5h", "W"])
        #expect(report.message == nil)
        #expect(report.sections[0].rows.contains { $0.label.hasPrefix("Prior window at") })
        #expect(report.sections[1].rows.contains { $0.label == "Last week at this point" })

        let json = try JSONSerialization.jsonObject(with: Data(report.json().utf8)) as? [String: Any]
        #expect((json?["sections"] as? [Any])?.count == 5)
    }

    @Test func reportWithoutAReadingSaysSo() {
        let empty = Meter(config: .default, snapshot: nil, history: [], status: FetchStatus(error: .noLogin))
        let report = Report(meter: empty, now: at("2026-10-22 10:00"), calendar: london)
        #expect(report.message == "Claude ⚠")
        #expect(report.error == UsageError.noLogin.errorDescription)
        #expect(report.sections[2].rows.first?.value == "today so far")
    }

    @Test func momentsRoundToTheMinute() {
        #expect(Format.moment(at("2026-10-27 02:59").addingTimeInterval(59), now: at("2026-10-22 10:00"), calendar: london) == "Tue 03:00")
    }

    @Test func deltas() {
        #expect([Format.delta(10.6), Format.delta(-4), Format.delta(0.2)] == ["+11", "−4", "±0"])
    }
}

@Suite struct VersionTests {
    @Test func readsTheVersionInTheCheckout() {
        #expect(Version.inRepo() == Version.current)
        #expect(Version.newerInRepo() == nil)
    }

    @Test func readsTheDeclaration() {
        #expect(Version.declared(in: "enum Version {\n    public static let current = \"1.4.0\"\n}") == "1.4.0")
        #expect(Version.declared(in: "nothing here") == nil)
    }

    @Test func comparesNumberByNumber() {
        #expect(Version.isLater("0.10.0", than: "0.9.1"))
        #expect(Version.isLater("0.2.1", than: "0.2.0"))
        #expect(!Version.isLater("0.2.0", than: "0.2.0"))
        #expect(!Version.isLater("0.1.9", than: "0.2.0"))
    }

    @Test func reportWarnsWhenTheRepoIsAhead() {
        let meter = Meter(config: .default, snapshot: nil, history: [])
        let report = Report(meter: meter, now: at("2026-10-22 10:00"), calendar: london, newerVersion: "9.0.0")
        #expect(report.outdated?.hasPrefix("Out of date: this is \(Version.current), the repo has 9.0.0.") == true)
        #expect(report.text.contains("the repo has 9.0.0"))
        #expect(Report(meter: meter, now: at("2026-10-22 10:00"), calendar: london).outdated == nil)
    }
}
