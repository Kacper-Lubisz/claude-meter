import Charts
import MeterCore
import SwiftUI

struct PopoverView: View {
    enum Tab: String, CaseIterable {
        case now = "Now", days = "Days", weeks = "Weeks", windows = "5h windows"
    }

    @ObservedObject var model: MeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("View", selection: $model.tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if let e = model.error, model.snapshot == nil {
                Text(e.localizedDescription).foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
            }
            switch model.tab {
            case .now:
                card("5-hour window", .fiveHour, model.fiveHour)
                Divider().overlay(Palette.hairline)
                card("Week", .week, model.week)
            case .days:
                DaysView(trends: model.trends, schedule: model.config.schedule, now: model.now,
                         picked: model.pickedDay, squeeze: $model.squeezeOffHours) { model.pickedDay = $0 }
            case .weeks:
                windows(.week)
            case .windows:
                windows(.fiveHour)
            }
            Divider().overlay(Palette.hairline)
            footer
        }
        .foregroundStyle(Palette.text)
        .padding(16)
        .frame(width: 340)
        .background(Palette.background)
    }

    private func windows(_ kind: LimitKind) -> WindowHistoryView {
        WindowHistoryView(kind: kind, trends: model.trends, schedule: model.config.schedule, now: model.now,
                          picked: model.pickedWindow[kind], squeeze: $model.squeezeOffHours) { model.pickedWindow[kind] = $0 }
    }

    private func card(_ title: String, _ kind: LimitKind, _ f: Forecast?) -> WindowCard {
        let latest = model.trends.latest(kind)
        let axis = f.map { TimeAxis(from: $0.windowStart, to: $0.resetsAt, schedule: model.config.schedule,
                                    weights: kind == .week && model.squeezeOffHours ? TimeAxis.squeezed : TimeAxis.toScale) }
        return WindowCard(title: title, forecast: f, now: model.now,
                          samples: latest?.readings.map { ($0.at, $0.used) } ?? [],
                          comparison: model.trends.compare(kind, now: model.now),
                          resets: latest.flatMap { $0.isOpen(at: model.now) ? $0.earlyResets : nil } ?? [],
                          axis: axis, labels: axis.map { kind == .week ? $0.dayLabels : $0.hourLabels } ?? [])
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let v = model.newerVersion {
                Text(Format.outdated(repo: v)).font(.caption).foregroundStyle(Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(Format.schedule(model.config.schedule, workingNow: model.isWorkingNow))
                .font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if let e = model.error, model.snapshot != nil {
                Text(e.localizedDescription).font(.caption).foregroundStyle(Palette.warn)
            }
            HStack {
                if let at = model.snapshot?.fetchedAt {
                    Text("Updated \(Format.countdown(model.now.timeIntervalSince(at))) ago").font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button(model.refreshing ? "Refreshing…" : "Refresh") { model.refresh() }.disabled(model.refreshing)
                Button("Settings") { NSWorkspace.shared.open(MeterConfig.url) }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
    }
}

struct WindowCard: View {
    let title: String
    let forecast: Forecast?
    let now: Date
    let samples: [(Date, Double)]
    let comparison: WindowComparison?
    /// Early resets in the open window.
    let resets: [EarlyReset]
    let axis: TimeAxis?
    let labels: [(Double, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(.caption.weight(.bold)).foregroundStyle(Palette.muted)
                Spacer()
                if let f = forecast {
                    Text("resets \(Format.moment(f.resetsAt, now: now)) · in \(Format.countdown(f.resetsAt.timeIntervalSince(now)))")
                        .font(.caption).foregroundStyle(Palette.muted)
                }
            }
            if let f = forecast {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.percent(f.utilization)).font(.system(size: 26, weight: .bold)).monospacedDigit()
                    Text(Format.verdict(f, now: now)).font(.callout.weight(.semibold)).foregroundStyle(Palette.status(f.status))
                }
                Track(forecast: f).frame(height: 10)
                chart(f)
                row("Burn rate", Format.rate(f.burnPerHour))
                row("Projected at reset", Format.percent(f.projected), f.status == .ok ? Palette.text : Palette.status(f.status))
                row("Work time left", Format.workHours(f.remainingWork))
                if let a = f.affordablePerHour { row("Pace to finish at 100%", Format.rate(a)) }
                if let c = comparison, c.isOpen { row(Format.baselineLabel(c), Format.comparison(c)) }
                ForEach(Array(resets.enumerated()), id: \.offset) { _, r in row("Reset early", Format.earlyReset(r, now: now)) }
            } else {
                Text("No data yet").foregroundStyle(Palette.muted)
            }
        }
    }

    private func row(_ k: String, _ v: String, _ c: Color = Palette.text) -> some View {
        HStack {
            Text(k).foregroundStyle(Palette.muted)
            Spacer()
            Text(v).monospacedDigit().fontWeight(.medium).foregroundStyle(c)
        }
        .font(.callout)
    }

    /// Usage so far in this window (what the limit shows, so it drops at an early reset),
    /// plus a dashed line to the projected value at reset.
    @ViewBuilder private func chart(_ f: Forecast) -> some View {
        let points = samples.filter { $0.0 >= f.windowStart }
        if points.count >= 2, let axis {
            let end = f.runsOutAt ?? f.resetsAt
            let endValue = f.runsOutAt != nil ? 100 : f.projected
            Chart {
                WorkBands(axis: axis)
                ResetMarks(xs: resets.map { axis.x($0.at) }, color: Palette.accent)
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", axis.x(p.0)), y: .value("Used", p.1), series: .value("s", "used"))
                        .foregroundStyle(Palette.accent).lineStyle(StrokeStyle(lineWidth: 2))
                }
                LineMark(x: .value("Time", axis.x(now)), y: .value("Used", f.utilization), series: .value("s", "proj"))
                    .foregroundStyle(Palette.status(f.status)).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                LineMark(x: .value("Time", axis.x(end)), y: .value("Used", endValue), series: .value("s", "proj"))
                    .foregroundStyle(Palette.status(f.status)).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                RuleMark(y: .value("Limit", 100)).foregroundStyle(Palette.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            .chartYScale(domain: 0...max(100, endValue))
            .timeAxis(axis, labels: labels)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { _ in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)))
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(height: 70)
        }
    }
}

/// Wide version of the menu bar's mini bar: fill = used, tick = working time elapsed.
struct Track: View {
    let forecast: Forecast

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let used = min(1, forecast.utilization / 100)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(Palette.fill(forecast.status)).frame(width: max(2, w * used))
                if let t = forecast.elapsedFraction {
                    Rectangle().fill(Palette.text)
                        .frame(width: 2, height: g.size.height + 6)
                        .padding(.horizontal, 1.5).background(Palette.background)
                        .offset(x: w * min(1, t) - 2.5)
                }
            }
        }
    }
}
