import Charts
import MeterCore
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let e = model.error, model.snapshot == nil {
                Text(e.localizedDescription).foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
            }
            WindowCard(title: "5-hour window", forecast: model.fiveHour, now: model.now,
                       samples: model.history.compactMap { s in s.fiveHour.map { (s.at, $0) } })
            Divider().overlay(Palette.hairline)
            WindowCard(title: "Week", forecast: model.week, now: model.now,
                       samples: model.history.compactMap { s in s.week.map { (s.at, $0) } })
            Divider().overlay(Palette.hairline)
            footer
        }
        .foregroundStyle(Palette.text)
        .padding(16)
        .frame(width: 340)
        .background(Palette.background)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            let s = model.config.schedule
            Text(model.isWorkingNow
                 ? "Counting \(days(s)) \(s.dayStart)–\(s.dayEnd)"
                 : "Outside working hours (\(days(s)) \(s.dayStart)–\(s.dayEnd)). Forecasts assume you stop until then.")
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

    private func days(_ s: WorkSchedule) -> String {
        s.workdays == [1, 2, 3, 4, 5] ? "Mon–Fri" : "\(s.workdays.count) days/wk"
    }
}

struct WindowCard: View {
    let title: String
    let forecast: Forecast?
    let now: Date
    let samples: [(Date, Double)]

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
                    Text(verdict(f)).font(.callout.weight(.semibold)).foregroundStyle(Palette.status(f.status))
                }
                Track(forecast: f).frame(height: 10)
                chart(f)
                row("Burn rate", Format.rate(f.burnPerHour))
                row("Projected at reset", Format.percent(f.projected), f.status == .ok ? Palette.text : Palette.status(f.status))
                row("Work time left", Format.workHours(f.remainingWork))
                if let a = f.affordablePerHour { row("Pace to finish at 100%", Format.rate(a)) }
            } else {
                Text("No data yet").foregroundStyle(Palette.muted)
            }
        }
    }

    private func verdict(_ f: Forecast) -> String {
        if f.utilization >= 100 { return "limit reached" }
        if let out = f.runsOutAt { return "runs out \(Format.moment(out, now: now))" }
        return f.status == .warn ? "cutting it close" : "on track"
    }

    private func row(_ k: String, _ v: String, _ c: Color = Palette.text) -> some View {
        HStack {
            Text(k).foregroundStyle(Palette.muted)
            Spacer()
            Text(v).monospacedDigit().fontWeight(.medium).foregroundStyle(c)
        }
        .font(.callout)
    }

    /// Usage so far in this window, plus a dashed line to the projected value at reset.
    @ViewBuilder private func chart(_ f: Forecast) -> some View {
        let points = samples.filter { $0.0 >= f.windowStart }
        if points.count >= 2 {
            let end = f.runsOutAt ?? f.resetsAt
            let endValue = f.runsOutAt != nil ? 100 : f.projected
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", p.0), y: .value("Used", p.1), series: .value("s", "used"))
                        .foregroundStyle(Palette.accent).lineStyle(StrokeStyle(lineWidth: 2))
                }
                LineMark(x: .value("Time", now), y: .value("Used", f.utilization), series: .value("s", "proj"))
                    .foregroundStyle(Palette.status(f.status)).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                LineMark(x: .value("Time", end), y: .value("Used", endValue), series: .value("s", "proj"))
                    .foregroundStyle(Palette.status(f.status)).lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                RuleMark(y: .value("Limit", 100)).foregroundStyle(Palette.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            .chartXScale(domain: f.windowStart...f.resetsAt)
            .chartYScale(domain: 0...max(100, endValue))
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Palette.hairline)
                    AxisValueLabel().foregroundStyle(Palette.muted)
                }
            }
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

/// Wide version of the menu bar's mini bar: solid = used, lighter = projected by reset.
struct Track: View {
    let forecast: Forecast

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let used = min(1, forecast.utilization / 100)
            let proj = min(1, max(used, forecast.projected / 100))
            let fill = Palette.fill(forecast.status)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(fill.opacity(0.35)).frame(width: w * proj)
                Capsule().fill(fill).frame(width: max(2, w * used))
            }
        }
    }
}
