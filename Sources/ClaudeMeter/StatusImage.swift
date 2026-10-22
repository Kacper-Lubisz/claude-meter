import AppKit
import MeterCore

/// Draws the menu bar item. A leading dot shows the most urgent window
/// (green on track, orange cutting it close, red on course to run out). Each window
/// then gets a mini bar (solid = used, light = projected by reset, red cap = overshoot)
/// plus its percent, coloured the same way when it needs attention.
/// Three widths, so it still fits when the menu bar is crowded:
///   full     label · 40pt bar · % · deadline (reset countdown, or when you'll run out)
///   medium   label · 26pt bar · %, and the deadline only when you're on course to run out
///   compact  both windows stacked on two thin rows, about 75pt wide
enum BarStyle: String, CaseIterable, Comparable {
    case full, medium, compact
    static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    var narrower: BarStyle? { self == .full ? .medium : self == .medium ? .compact : nil }
}

enum StatusImage {
    static let height: CGFloat = 22
    static let dotSize: CGFloat = 8

    struct Item { var label: String; var forecast: Forecast? }

    static func make(_ items: [Item], now: Date, style: BarStyle, message: String? = nil) -> NSImage {
        if let message { return text(message) }
        let worst = items.compactMap(\.forecast?.status).max()
        return style == .compact ? stacked(items, worst: worst) : inline(items, now: now, style: style, worst: worst)
    }

    static func color(_ s: PaceStatus) -> NSColor {
        switch s { case .ok: .systemGreen; case .warn: .systemOrange; case .over: .systemRed }
    }

    /// Text colour for a window's percent: plain when fine, the alert colour otherwise.
    private static func valueColor(_ f: Forecast?) -> NSColor {
        guard let s = f?.status, s != .ok else { return .labelColor }
        return color(s)
    }

    private static func str(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    private static func text(_ message: String) -> NSImage {
        let s = str(message, .monospacedDigitSystemFont(ofSize: 12, weight: .medium), .labelColor)
        return NSImage(size: NSSize(width: ceil(s.size().width) + 4, height: height), flipped: false) { _ in
            s.draw(at: NSPoint(x: 2, y: (height - s.size().height) / 2)); return true
        }
    }

    private static func dot(at x: CGFloat, _ worst: PaceStatus?) {
        guard let worst else { return }
        let r = NSRect(x: x, y: (height - dotSize) / 2, width: dotSize, height: dotSize)
        color(worst).setFill()
        NSBezierPath(ovalIn: r).fill()
    }

    // MARK: full / medium

    private static func inline(_ items: [Item], now: Date, style: BarStyle, worst: PaceStatus?) -> NSImage {
        let full = style == .full
        let barW: CGFloat = full ? 40 : 26, barH: CGFloat = 7
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .heavy)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let subFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        let gap: CGFloat = full ? 4 : 3, groupGap: CGFloat = full ? 10 : 7
        let lead: CGFloat = worst == nil ? 0 : dotSize + (full ? 7 : 5)

        struct Piece { var label, value, sub: NSAttributedString; var f: Forecast? }
        let pieces: [Piece] = items.map { item in
            let label = str(full ? item.label : item.label.hasPrefix("5") ? "5h" : "W", labelFont, .labelColor)
            guard let f = item.forecast else {
                return Piece(label: label, value: str("–", valueFont, .labelColor), sub: NSAttributedString(), f: nil)
            }
            let showSub = full || f.runsOutAt != nil
            let subColor = f.status == .over ? NSColor.systemRed : NSColor.labelColor
            return Piece(label: label, value: str(Format.percent(f.utilization), valueFont, valueColor(f)),
                         sub: showSub ? str(Format.barDeadline(f, now: now), subFont, subColor) : NSAttributedString(),
                         f: f)
        }
        func width(_ p: Piece) -> CGFloat {
            ceil(p.label.size().width) + gap + barW + 3 + gap + ceil(p.value.size().width)
                + (p.sub.length > 0 ? gap + ceil(p.sub.size().width) : 0)
        }
        let total = lead + pieces.map(width).reduce(0, +) + groupGap * CGFloat(max(0, pieces.count - 1)) + 4

        return NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            dot(at: 2, worst)
            var x: CGFloat = 2 + lead
            for p in pieces {
                func draw(_ s: NSAttributedString) {
                    s.draw(at: NSPoint(x: x, y: (height - s.size().height) / 2)); x += ceil(s.size().width)
                }
                draw(p.label); x += gap
                bar(NSRect(x: x, y: (height - barH) / 2, width: barW, height: barH), p.f, cap: 3)
                x += barW + 3 + gap
                draw(p.value)
                if p.sub.length > 0 { x += gap; draw(p.sub) }
                x += groupGap
            }
            return true
        }
    }

    // MARK: compact

    private static func stacked(_ items: [Item], worst: PaceStatus?) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .heavy)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        let lead: CGFloat = worst == nil ? 0 : dotSize + 4
        let labelW: CGFloat = 12, barW: CGFloat = 22, barH: CGFloat = 4
        let valueW = ceil(str("100%", valueFont, .labelColor).size().width)
        let total = 2 + lead + labelW + barW + 2 + 3 + valueW + 2
        let rowH: CGFloat = 10

        return NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            dot(at: 2, worst)
            let x0 = 2 + lead
            for (i, item) in items.prefix(2).enumerated() {
                let midY = height / 2 + (i == 0 ? rowH / 2 : -rowH / 2) // first item on top
                let label = str(item.label.hasPrefix("5") ? "5h" : "W", labelFont, .labelColor)
                label.draw(at: NSPoint(x: x0, y: midY - label.size().height / 2))
                bar(NSRect(x: x0 + labelW, y: midY - barH / 2, width: barW, height: barH), item.forecast, cap: 2)
                let v = str(item.forecast.map { Format.percent($0.utilization) } ?? "–", valueFont, valueColor(item.forecast))
                v.draw(at: NSPoint(x: x0 + labelW + barW + 2 + 3, y: midY - v.size().height / 2))
            }
            return true
        }
    }

    // MARK: bar

    private static func bar(_ track: NSRect, _ f: Forecast?, cap: CGFloat) {
        let r = min(2, track.height / 2)
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
        guard let f else { return }

        let used = min(1, max(0, f.utilization / 100))
        let projected = min(1, max(used, f.projected / 100))
        let fill = f.status == .ok ? NSColor.labelColor : color(f.status)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).addClip()
        fill.withAlphaComponent(0.45).setFill()
        NSRect(x: track.minX, y: track.minY, width: track.width * projected, height: track.height).fill()
        fill.setFill()
        NSRect(x: track.minX, y: track.minY, width: track.width * used, height: track.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        if f.status == .over {
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.maxX, y: track.minY - 2, width: cap, height: track.height + 4),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}
