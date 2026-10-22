import AppKit
import MeterCore

/// Draws the menu bar item. Each window gets a mini bar (solid = used,
/// light = projected by reset, red cap = overshoot) plus its percent.
/// Three widths, so it still fits when the menu bar is crowded:
///   full     label · 40pt bar · % · deadline (reset countdown, or when you'll run out)
///   medium   label · 26pt bar · %, and the deadline only when you're on course to run out
///   compact  both windows stacked on two thin rows, about 55pt wide
enum BarStyle: String, CaseIterable, Comparable {
    case full, medium, compact
    static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
    var narrower: BarStyle? { self == .full ? .medium : self == .medium ? .compact : nil }
}

enum StatusImage {
    static let height: CGFloat = 22

    struct Item { var label: String; var forecast: Forecast? }

    static func make(_ items: [Item], now: Date, style: BarStyle, message: String? = nil) -> NSImage {
        if let message { return text(message) }
        return style == .compact ? stacked(items) : inline(items, now: now, style: style)
    }

    private static func str(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    private static func text(_ message: String) -> NSImage {
        let s = str(message, .monospacedDigitSystemFont(ofSize: 12, weight: .medium), .secondaryLabelColor)
        return NSImage(size: NSSize(width: ceil(s.size().width) + 4, height: height), flipped: false) { _ in
            s.draw(at: NSPoint(x: 2, y: (height - s.size().height) / 2)); return true
        }
    }

    // MARK: full / medium

    private static func inline(_ items: [Item], now: Date, style: BarStyle) -> NSImage {
        let full = style == .full
        let barW: CGFloat = full ? 40 : 26, barH: CGFloat = 7
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let subFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let gap: CGFloat = full ? 4 : 3, groupGap: CGFloat = full ? 10 : 7

        struct Piece { var label, value, sub: NSAttributedString; var f: Forecast? }
        let pieces: [Piece] = items.map { item in
            let label = str(full ? item.label : item.label.prefix(1).lowercased() == "5" ? "5h" : "W",
                            labelFont, .secondaryLabelColor)
            guard let f = item.forecast else {
                return Piece(label: label, value: str("–", valueFont, .labelColor), sub: NSAttributedString(), f: nil)
            }
            let showSub = full || f.runsOutAt != nil
            return Piece(label: label, value: str(Format.percent(f.utilization), valueFont, .labelColor),
                         sub: showSub ? str(Format.barDeadline(f, now: now), subFont,
                                            f.status == .over ? .systemRed : .secondaryLabelColor) : NSAttributedString(),
                         f: f)
        }
        func width(_ p: Piece) -> CGFloat {
            ceil(p.label.size().width) + gap + barW + 3 + gap + ceil(p.value.size().width)
                + (p.sub.length > 0 ? gap + ceil(p.sub.size().width) : 0)
        }
        let total = pieces.map(width).reduce(0, +) + groupGap * CGFloat(max(0, pieces.count - 1)) + 4

        return NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            var x: CGFloat = 2
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

    private static func stacked(_ items: [Item]) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 7, weight: .bold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let labelW: CGFloat = 10, barW: CGFloat = 22, barH: CGFloat = 4
        let valueW = ceil(str("100%", valueFont, .labelColor).size().width)
        let total = 2 + labelW + barW + 2 + 3 + valueW + 2
        let rowH: CGFloat = 10

        return NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            for (i, item) in items.prefix(2).enumerated() {
                let midY = height / 2 + (i == 0 ? rowH / 2 : -rowH / 2) // first item on top
                let label = str(item.label.hasPrefix("5") ? "5h" : "W", labelFont, .secondaryLabelColor)
                label.draw(at: NSPoint(x: 2, y: midY - label.size().height / 2))
                bar(NSRect(x: 2 + labelW, y: midY - barH / 2, width: barW, height: barH), item.forecast, cap: 2)
                let v = str(item.forecast.map { Format.percent($0.utilization) } ?? "–", valueFont,
                            item.forecast?.status == .over ? .systemRed : .labelColor)
                v.draw(at: NSPoint(x: 2 + labelW + barW + 2 + 3, y: midY - v.size().height / 2))
            }
            return true
        }
    }

    // MARK: bar

    private static func bar(_ track: NSRect, _ f: Forecast?, cap: CGFloat) {
        let r = min(2, track.height / 2)
        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).fill()
        guard let f else { return }

        let used = min(1, max(0, f.utilization / 100))
        let projected = min(1, max(used, f.projected / 100))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: r, yRadius: r).addClip()
        NSColor.labelColor.withAlphaComponent(0.42).setFill()
        NSRect(x: track.minX, y: track.minY, width: track.width * projected, height: track.height).fill()
        (f.status == .over ? NSColor.systemRed : f.status == .warn ? NSColor.systemOrange : NSColor.labelColor).setFill()
        NSRect(x: track.minX, y: track.minY, width: track.width * used, height: track.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        if f.status == .over {
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.maxX, y: track.minY - 2, width: cap, height: track.height + 4),
                         xRadius: 1, yRadius: 1).fill()
        }
    }
}
