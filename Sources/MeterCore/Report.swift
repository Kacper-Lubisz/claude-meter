import Foundation

/// What `claude-meter status` prints, and what the GNOME extension draws from its JSON: the
/// panel item plus the menu's sections, already worded, so every front end says the same thing.
public struct Report: Encodable, Sendable {
    public struct PanelItem: Encodable, Sendable {
        public var label: String
        /// Fill, 0...1.
        public var used: Double?
        /// The time tick: how far through the window's working time we are, 0...1.
        public var elapsed: Double?
        public var status: String?
        public var value: String
        /// When you'll run out, only while on course to.
        public var detail: String?
    }

    public struct Row: Encodable, Sendable {
        public var label: String
        public var value: String = ""
        /// "ok", "warn", "over", or "muted".
        public var tone: String?
        /// A bar drawn with the row, 0...1.
        public var bar: Double?
        /// The window's headline figure.
        public var emphasis: Bool?
    }

    public struct Section: Encodable, Sendable {
        public var title: String
        public var note: String?
        public var rows: [Row]
        /// "window" for a live limit, "comparison" for days, weeks and past windows
        /// (which the GNOME menu folds into submenus to fit on screen).
        public var kind = "comparison"
    }

    /// The more urgent window's status, for the dot.
    public var status: String?
    /// Shown instead of the items when there's no reading yet.
    public var message: String?
    public var items: [PanelItem]
    public var sections: [Section]
    public var footer: [String]
    public var error: String?
    /// A warning that the repo has a later version than this build.
    public var outdated: String?

    /// Day bars and window lists in the menu.
    static let dayCount = 7, weekCount = 5, windowCount = 6

    /// `newerVersion`: the repo's version, when it's later than this build's (`Version.newerInRepo()`).
    public init(meter: Meter, now: Date, calendar: Calendar = .current, newerVersion: String? = nil) {
        let five = meter.forecast(.fiveHour, now: now, calendar: calendar)
        let week = meter.forecast(.week, now: now, calendar: calendar)
        let trends = meter.trends
        let schedule = meter.config.schedule

        status = [five, week].compactMap { $0?.status }.max()?.name
        message = meter.snapshot != nil ? nil : meter.status.error == nil ? "Claude…" : "Claude ⚠"
        items = [Self.item("5h", five, now: now), Self.item("W", week, now: now)]
        error = meter.status.error?.localizedDescription
        outdated = newerVersion.map { Format.outdated(repo: $0) }

        sections = [
            Self.window("5-hour window", five, trends, .fiveHour, now: now, calendar: calendar),
            Self.window("Week", week, trends, .week, now: now, calendar: calendar),
            Self.days(trends, schedule: schedule, now: now, calendar: calendar),
            Self.weeks(trends, now: now, calendar: calendar),
            Self.fiveHourWindows(trends, now: now, calendar: calendar),
        ]

        var footer: [String] = []
        if let at = meter.snapshot?.fetchedAt { footer.append("Updated \(Format.countdown(now.timeIntervalSince(at))) ago") }
        if let error { footer.append(error) }
        footer.append(Format.schedule(schedule, workingNow: schedule.isWorking(at: now, calendar: calendar)))
        self.footer = footer
    }

    static func item(_ label: String, _ f: Forecast?, now: Date) -> PanelItem {
        guard let f else { return PanelItem(label: label, value: "–") }
        return PanelItem(label: label, used: min(1, max(0, f.utilization / 100)), elapsed: f.elapsedFraction,
                         status: f.status.name, value: Format.percent(f.utilization),
                         detail: f.runsOutAt.map { Format.moment($0, now: now) })
    }

    static func window(_ title: String, _ f: Forecast?, _ t: Trends, _ kind: LimitKind, now: Date, calendar: Calendar) -> Section {
        guard let f else { return Section(title: title, rows: [Row(label: "No data yet", tone: "muted")], kind: "window") }
        let c = t.compare(kind, now: now)
        var rows = [
            Row(label: Format.percent(f.utilization), value: Format.verdict(f, now: now), tone: f.status.name, emphasis: true),
            Row(label: "Burn rate", value: Format.rate(f.burnPerHour)),
            Row(label: "Projected at reset", value: Format.percent(f.projected), tone: f.status == .ok ? nil : f.status.name),
            Row(label: "Work time left", value: Format.workHours(f.remainingWork)),
        ]
        if let a = f.affordablePerHour { rows.append(Row(label: "Pace to finish at 100%", value: Format.rate(a))) }
        if let c, c.isOpen { rows.append(Row(label: Format.baselineLabel(c, calendar: calendar), value: Format.comparison(c))) }
        if let w = t.latest(kind), w.isOpen(at: now) {
            rows += w.earlyResets.map { Row(label: "Reset early", value: Format.earlyReset($0, now: now, calendar: calendar)) }
        }
        return Section(title: title, note: "resets \(Format.moment(f.resetsAt, now: now)) · in \(Format.countdown(f.resetsAt.timeIntervalSince(now)))",
                       rows: rows, kind: "window")
    }

    static func days(_ t: Trends, schedule: WorkSchedule, now: Date, calendar: Calendar) -> Section {
        let days = t.days(endingAt: now, count: dayCount, calendar: calendar)
        guard let today = days.last else { return Section(title: "Days", rows: []) }
        var rows = [Row(label: Format.percent(today.used), value: "today so far", emphasis: true)]
        if let base = Trends.defaultBaseline(in: days, schedule: schedule, calendar: calendar) {
            let then = base.used(by: Trends.sameTime(as: now, on: base.day, calendar: calendar))
            rows.append(Row(label: "\(Format.day(base.day, now: now, calendar: calendar)) by \(Format.moment(now, now: now, calendar: calendar))",
                            value: "\(Format.percent(then)) → \(Format.percent(today.used)) (\(Format.delta(today.used - then)))"))
        }
        let top = max(1, days.map(\.used).max() ?? 0)
        for d in days.reversed() {
            rows.append(d.hasReadings
                ? Row(label: Format.day(d.day, now: now, calendar: calendar), value: Format.percent(d.used), bar: d.used / top)
                : Row(label: Format.day(d.day, now: now, calendar: calendar), value: "no readings", tone: "muted"))
        }
        return Section(title: "Days", note: "share of the weekly limit used each day", rows: rows)
    }

    static func weeks(_ t: Trends, now: Date, calendar: Calendar) -> Section {
        let weeks = Array(t.weeks.suffix(weekCount))
        guard let current = weeks.last else { return Section(title: "Weeks", rows: [Row(label: "No readings yet", tone: "muted")]) }
        let open = current.isOpen(at: now)
        var rows = [Row(label: Format.percent(current.used), value: open ? "this week so far" : "latest week", emphasis: true)]
        if let c = t.compare(.week, now: now) {
            rows.append(Row(label: Format.baselineLabel(c, calendar: calendar), value: Format.comparison(c)))
        }
        let top = max(1, weeks.map(\.used).max() ?? 0)
        for w in weeks.reversed() {
            rows.append(Row(label: "From \(Format.weekStart(w.start, calendar: calendar))" + Format.marks(w, now: now),
                            value: Format.percent(w.used), bar: w.used / top))
        }
        return Section(title: "Weeks", note: "each weekly window, by when it opened · ↺ reset early", rows: rows)
    }

    static func fiveHourWindows(_ t: Trends, now: Date, calendar: Calendar) -> Section {
        let windows = Array(t.fiveHourWindows.suffix(windowCount)).reversed()
        guard !windows.isEmpty else { return Section(title: "5-hour windows", rows: [Row(label: "No readings yet", tone: "muted")]) }
        let rows = windows.map { w -> Row in
            var value = Format.percent(w.used)
            if let c = t.compare(.fiveHour, now: now, subject: w), let d = c.delta { value += " · \(Format.delta(d))" }
            value += " · \(Format.percent(t.weekUse(during: w, now: now))) of week"
            let label = Format.moment(w.start, now: now, calendar: calendar) + Format.marks(w, now: now)
            return Row(label: label, value: value)
        }
        return Section(title: "5-hour windows", note: "used · change on the window before · weekly limit used · ↺ reset early", rows: rows)
    }

    // MARK: Output

    public func json() -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// For a terminal.
    public var text: String {
        let width = 52
        func line(_ l: String, _ r: String, indent: String = "  ") -> String {
            let gap = max(1, width - indent.count - l.count - r.count)
            return indent + l + String(repeating: " ", count: gap) + r
        }
        var out: [String] = []
        let bar = items.map { "\($0.label) \($0.value)" + ($0.detail.map { " (runs out \($0))" } ?? "") }.joined(separator: "   ")
        out.append(message ?? bar)
        for s in sections {
            out.append("")
            out.append(s.note.map { line(s.title.uppercased(), $0, indent: "") } ?? s.title.uppercased())
            for r in s.rows {
                let value = r.bar.map { String(repeating: "▇", count: Int(($0 * 12).rounded())) + " " + r.value } ?? r.value
                out.append(line(r.label, value))
            }
        }
        out.append("")
        if let outdated { out.append(outdated) }
        out.append(contentsOf: footer)
        return out.joined(separator: "\n")
    }
}

extension PaceStatus {
    public var name: String {
        switch self { case .ok: "ok"; case .warn: "warn"; case .over: "over" }
    }
}

extension Format {
    /// "Prior window at 2h10", "Last week at this point", "From Tue 6 Oct at this point".
    public static func baselineLabel(_ c: WindowComparison, calendar: Calendar = .current) -> String {
        let consecutive = abs(c.subject.start.timeIntervalSince(c.baseline.start) - c.subject.kind.length) < 3600
        switch (c.subject.kind, c.isOpen) {
        case (.fiveHour, true): return "Prior window at \(countdown(c.offset))"
        case (.fiveHour, false): return "Prior window"
        case (.week, let open):
            let name = consecutive ? "Last week" : "From \(weekStart(c.baseline.start, calendar: calendar))"
            return open ? "\(name) at this point" : name
        }
    }

    /// " (open)" and " ↺" (reset early), after a window's name in a list.
    public static func marks(_ w: UsageWindow, now: Date) -> String {
        (w.isOpen(at: now) ? " (open)" : "") + (w.earlyResets.isEmpty ? "" : " ↺")
    }

    /// The working-hours note at the foot of the popover and menu.
    public static func schedule(_ s: WorkSchedule, workingNow: Bool) -> String {
        let days = s.workdays == [1, 2, 3, 4, 5] ? "Mon–Fri" : "\(s.workdays.count) days/wk"
        return workingNow
            ? "Counting \(days) \(s.dayStart)–\(s.dayEnd)"
            : "Outside working hours (\(days) \(s.dayStart)–\(s.dayEnd)). Forecasts assume you stop until then."
    }
}
