import Charts
import MeterCore
import SwiftUI

/// Today against another day (by default the last working day): weekly-limit use through
/// the day, and a bar per day for the last two weeks. Click a bar to compare with that day.
struct DaysView: View {
    let trends: Trends
    let schedule: WorkSchedule
    let now: Date
    let picked: Date?
    let squeeze: Binding<Bool>
    let pick: (Date) -> Void

    var body: some View {
        let days = trends.days(endingAt: now, count: 14)
        if let today = days.last {
            let base = days.dropLast().first { $0.day == picked } ?? Trends.defaultBaseline(in: days, schedule: schedule)
            let axis = TimeAxis(from: today.day, to: Calendar.current.date(byAdding: .day, value: 1, to: today.day) ?? now,
                                schedule: schedule, weights: squeeze.wrappedValue ? TimeAxis.squeezed : TimeAxis.toScale)
            VStack(alignment: .leading, spacing: 8) {
                Heading(title: "Today", detail: "share of the weekly limit used")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.percent(today.used)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                    if let base {
                        let then = base.used(by: Trends.sameTime(as: now, on: base.day))
                        Text("\(Format.delta(today.used - then)) vs \(Format.day(base.day, now: now, midSentence: true)) by now")
                            .font(.callout.weight(.semibold))
                    }
                }
                HStack {
                    Legend(current: "Today", baseline: base.map { Format.day($0.day, now: now) })
                    Spacer()
                    SqueezeToggle(isOn: squeeze)
                }
                OverlayChart(current: Self.points(today, until: now, on: axis),
                             baseline: base.map { Self.points($0, until: nil, on: axis) } ?? [],
                             axis: axis, labels: axis.clockTicks.map { (axis.x($0), Format.clock($0)) })
                DayBars(days: days, picked: base?.day, now: now, pick: pick)
                if let base {
                    let name = Format.day(base.day, now: now)
                    Row(label: "\(name) by \(Format.moment(now, now: now))",
                        value: Format.percent(base.used(by: Trends.sameTime(as: now, on: base.day))))
                    Row(label: "\(name) in all", value: base.hasReadings ? Format.percent(base.used) : "no readings")
                }
            }
        }
    }

    /// Running total by clock time on today's axis, from midnight to now (today) or to the end of the day.
    static func points(_ d: DayUsage, until now: Date?, on axis: TimeAxis) -> [(Double, Double)] {
        let cal = Calendar.current
        func x(_ t: Date) -> Double {
            let c = cal.dateComponents([.hour, .minute, .second], from: t)
            return axis.x(axis.start.addingTimeInterval(Double(c.hour! * 3600 + c.minute! * 60 + c.second!)))
        }
        return [(0, 0)] + d.cumulative.map { (x($0.at), $0.used) } + [(now.map(x) ?? axis.length, d.used)]
    }
}

/// One limit's windows: the latest against another (by default the one before it) on one
/// chart, and a list of recent windows, each against the window before it. Click a row to
/// compare the latest window with it.
struct WindowHistoryView: View {
    let kind: LimitKind
    let trends: Trends
    let schedule: WorkSchedule
    let now: Date
    let picked: Date?
    let squeeze: Binding<Bool>
    let pick: (Date) -> Void

    var body: some View {
        let windows = Array(trends.windows(kind).suffix(kind == .week ? 6 : 8))
        if let subject = windows.last {
            let open = subject.isOpen(at: now)
            let base = windows.dropLast().first { $0.start == picked } ?? trends.window(before: subject)
            let c = base.flatMap { trends.compare(kind, now: now, subject: subject, baseline: $0) }
            let axis = TimeAxis(from: subject.start, to: subject.start.addingTimeInterval(kind.length), schedule: schedule,
                                weights: kind == .week && squeeze.wrappedValue ? TimeAxis.squeezed : TimeAxis.toScale)
            VStack(alignment: .leading, spacing: 8) {
                Heading(title: kind == .week ? (open ? "This week" : "Latest week") : (open ? "This window" : "Latest window"),
                        detail: "since \(name(subject))" + (subject.openedEarly == nil ? "" : " (early reset)")
                            + (subject.resetsAt.map { " · \(open ? "resets" : "reset") \(Format.moment($0, now: now))" } ?? ""))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.percent(subject.used)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                    if let c, let d = c.delta {
                        Text("\(Format.delta(d)) vs \(name(c.baseline))" + (open ? " at this point" : ""))
                            .font(.callout.weight(.semibold))
                    }
                }
                HStack {
                    Legend(current: open ? "Now" : name(subject), baseline: base.map(name))
                    Spacer()
                    if kind == .week { SqueezeToggle(isOn: squeeze) }
                }
                OverlayChart(current: points(subject, on: axis), baseline: base.map { points($0, on: axis) } ?? [],
                             axis: axis, labels: labels(axis),
                             resets: (resets(subject, on: axis), base.map { resets($0, on: axis) } ?? []))
                list(windows, subject: subject, baseline: base)
            }
        } else {
            Text("No readings yet").foregroundStyle(Palette.muted)
        }
    }

    private func name(_ w: UsageWindow) -> String {
        kind == .week ? Format.weekStart(w.start) : Format.moment(w.start, now: now)
    }

    /// Where a moment in `w` goes on the subject's axis: windows line up by time since each opened.
    private func x(_ t: Date, in w: UsageWindow, on axis: TimeAxis) -> Double {
        axis.x(axis.start.addingTimeInterval(t.timeIntervalSince(w.start)))
    }

    private func points(_ w: UsageWindow, on axis: TimeAxis) -> [(Double, Double)] {
        var p = w.progress.map { (x($0.at, in: w, on: axis), $0.used) }
        if !w.isOpen(at: now) { p.append((x(w.end, in: w, on: axis), w.used)) }
        return p
    }

    private func resets(_ w: UsageWindow, on axis: TimeAxis) -> [Double] {
        w.earlyResets.map { x($0.at, in: w, on: axis) }
    }

    private func labels(_ axis: TimeAxis) -> [(Double, String)] {
        kind == .week ? axis.dayLabels : (0...5).map { (axis.x(axis.start.addingTimeInterval(Double($0) * 3600)), "\($0)h") }
    }

    private func list(_ windows: [UsageWindow], subject: UsageWindow, baseline: UsageWindow?) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(kind == .week ? "Opened" : "Started").frame(maxWidth: .infinity, alignment: .leading)
                Text("Used").frame(width: 56, alignment: .trailing)
                Text("vs before").frame(width: 62, alignment: .trailing)
                if kind == .fiveHour { Text("Of week").frame(width: 52, alignment: .trailing) }
            }
            .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            ForEach(windows.reversed(), id: \.start) { w in
                let isSubject = w == subject, isBase = w == baseline
                Button { if !isSubject { pick(w.start) } } label: {
                    HStack {
                        Circle().fill(isSubject ? Palette.accent : isBase ? Palette.muted : .clear).frame(width: 7, height: 7)
                        Text(name(w) + (w.earlyResets.isEmpty ? "" : " ↺")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Format.percent(w.used)).frame(width: 56, alignment: .trailing)
                        Text(trends.compare(kind, now: now, subject: w).flatMap(\.delta).map(Format.delta) ?? "–")
                            .frame(width: 62, alignment: .trailing)
                        if kind == .fiveHour {
                            Text(Format.percent(trends.weekUse(during: w, now: now))).frame(width: 52, alignment: .trailing)
                        }
                    }
                    .font(.callout.weight(isSubject ? .semibold : .regular)).monospacedDigit()
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(w.earlyResets.map { "Reset early \(Format.earlyReset($0, now: now))" }.joined(separator: "\n"))
            }
        }
    }
}

/// Two periods on one chart, lined up by time since each began: the current one in the
/// accent colour, the one it's compared with in grey. Both are running totals that change
/// at readings, so they're drawn as steps.
struct OverlayChart: View {
    let current: [(Double, Double)]
    let baseline: [(Double, Double)]
    let axis: TimeAxis
    let labels: [(Double, String)]
    /// Early resets in each period, as x.
    var resets: (current: [Double], baseline: [Double]) = ([], [])

    var body: some View {
        let top = max(10, ((current + baseline).map(\.1).max() ?? 0) * 1.1)
        Chart {
            WorkBands(axis: axis)
            ResetMarks(xs: resets.baseline, color: Palette.muted)
            ResetMarks(xs: resets.current, color: Palette.accent)
            ForEach(Array(baseline.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.0), y: .value("Used", p.1), series: .value("Series", "baseline"))
                    .foregroundStyle(Palette.muted).lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.stepEnd)
            }
            ForEach(Array(current.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("Time", p.0), y: .value("Used", p.1), series: .value("Series", "current"))
                    .foregroundStyle(Palette.accent).lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.stepEnd)
            }
            if let last = current.last {
                PointMark(x: .value("Time", last.0), y: .value("Used", last.1))
                    .foregroundStyle(Palette.accent).symbolSize(24)
            }
        }
        .chartYScale(domain: 0...top)
        .timeAxis(axis, labels: labels)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(height: 100)
    }
}

/// A bar per day, today last in the accent colour. The day being compared with is underlined.
struct DayBars: View {
    let days: [DayUsage]
    let picked: Date?
    let now: Date
    let pick: (Date) -> Void

    var body: some View {
        let top = max(1, days.map(\.used).max() ?? 0)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days, id: \.day) { d in
                let isToday = d.day == days.last?.day, isPicked = d.day == picked
                Button { if !isToday { pick(d.day) } } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            Color.clear.frame(height: 40)
                            if d.hasReadings {
                                RoundedRectangle(cornerRadius: 2).fill(isToday ? Palette.accent : Palette.muted)
                                    .frame(height: max(2, 40 * d.used / top))
                            } else {
                                Rectangle().fill(Palette.hairline).frame(height: 1)
                            }
                        }
                        Text(Format.weekday(d.day).prefix(1))
                            .font(.caption2.weight(isPicked || isToday ? .bold : .regular))
                            .foregroundStyle(isPicked || isToday ? Palette.text : Palette.muted)
                        Rectangle().fill(isPicked ? Palette.text : .clear).frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(Format.day(d.day, now: now)): \(d.hasReadings ? Format.percent(d.used) : "no readings")")
            }
        }
    }
}

/// Working hours, shaded behind a chart's lines so the working days stand out.
struct WorkBands: ChartContent {
    let axis: TimeAxis

    var body: some ChartContent {
        ForEach(Array(axis.workBands.enumerated()), id: \.offset) { _, band in
            RectangleMark(xStart: .value("From", band.lowerBound), xEnd: .value("To", band.upperBound))
                .foregroundStyle(Palette.band)
        }
    }
}

/// A dashed line and ↺ at each early reset.
struct ResetMarks: ChartContent {
    let xs: [Double]
    let color: Color

    var body: some ChartContent {
        ForEach(Array(xs.enumerated()), id: \.offset) { _, x in
            RuleMark(x: .value("Reset", x))
                .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .annotation(position: .overlay, alignment: .topTrailing, spacing: 2) {
                    Text("↺").font(.caption2.weight(.bold)).foregroundStyle(color)
                }
        }
    }
}

extension View {
    /// A chart's x axis along `axis`: a grid line between days, and `labels` under it.
    func timeAxis(_ axis: TimeAxis, labels: [(Double, String)]) -> some View {
        chartXScale(domain: 0...max(1, axis.length))
            .chartXAxis {
                AxisMarks(values: axis.midnights) { _ in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                }
                AxisMarks(values: labels.map(\.0)) { v in
                    let x = v.as(Double.self) ?? 0
                    // Centred on its point, a label at the very start would hang off the chart and be dropped.
                    AxisValueLabel(anchor: x == 0 ? .topLeading : .top) {
                        if let l = labels.first(where: { $0.0 == x }) {
                            Text(l.1).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
    }
}

extension TimeAxis {
    /// A weekday under each day, in the middle of its working hours. A squeezed day off just gets its initial.
    var dayLabels: [(Double, String)] {
        days.compactMap { d in
            let share = d.width / max(1, length)
            guard share >= 0.04 else { return nil }
            let name = Format.weekday(d.date)
            return (d.middle, share >= 0.09 ? name : String(name.prefix(1)))
        }
    }

    var hourLabels: [(Double, String)] { hourTicks.map { (x($0), Format.clock($0)) } }
}

/// Squeezes evenings, nights and weekends on the time axis, so the working days stand out.
struct SqueezeToggle: View {
    let isOn: Binding<Bool>

    var body: some View {
        Toggle("Squeeze off-hours", isOn: isOn)
            .toggleStyle(.checkbox).controlSize(.small).font(.caption)
            .help("Evenings, nights and weekends take up less of the chart")
    }
}

struct Heading: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Palette.muted)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(Palette.muted)
        }
    }
}

struct Legend: View {
    let current: String
    let baseline: String?

    var body: some View {
        HStack(spacing: 12) {
            key(current, Palette.accent)
            if let baseline { key(baseline, Palette.muted) }
        }
        .font(.caption)
    }

    private func key(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 12, height: 3)
            Text(label).foregroundStyle(Palette.text)
        }
    }
}

struct Row: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Palette.muted)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.medium)
        }
        .font(.callout)
    }
}
