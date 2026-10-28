import AppKit
import MeterCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Lazy so the preview modes never load (or migrate) the real history.
    private lazy var model = MeterModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    /// Fixed rather than fitted to the free space: switching widths as the menu bar
    /// filled up made the item jump around.
    private lazy var style = model.config.barStyle.flatMap(BarStyle.init(rawValue:)) ?? .compact

    func applicationDidFinishLaunching(_ note: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--preview-popover"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            Task { await Preview.renderPopover(to: path); NSApp.terminate(nil) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            Task { await Preview.render(to: path, schedule: MeterConfig.load().schedule); NSApp.terminate(nil) }
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)

        popover.behavior = .transient
        let content = NSHostingController(rootView: PopoverView(model: model))
        content.sizingOptions = .preferredContentSize // tabs differ in height; the popover follows
        popover.contentViewController = content

        model.onChange = { [weak self] in self?.redraw() }
        redraw()
        model.start()
    }

    private func redraw() {
        let message: String? = model.snapshot == nil ? (model.error == nil ? "Claude…" : "Claude ⚠") : nil
        let items: [StatusImage.Item] = [.init(label: "5H", forecast: model.fiveHour),
                                         .init(label: "WK", forecast: model.week)]
        let img = StatusImage.make(items, now: model.now, style: style, message: message)
        statusItem.button?.image = img
        statusItem.length = img.size.width + 8
        statusItem.button?.toolTip = model.error?.localizedDescription ?? "Top: 5-hour window · Bottom: week"
    }

    @objc private func toggle() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refreshIfStale()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Goes to stderr, which the LaunchAgent sends to ~/Library/Logs/ClaudeMeter.log.
func log(_ msg: String) {
    FileHandle.standardError.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(msg)\n".utf8))
}

/// `ClaudeMeter --preview out.png` renders every bar style, with live data and a sample
/// overshoot, in light and dark, so the drawing can be checked without a screenshot.
@MainActor
enum Preview {
    static func render(to path: String, schedule: WorkSchedule) async {
        let now = Date()
        let live = try? await UsageClient().fetch()
        func fc(_ w: LimitWindow?, _ len: TimeInterval) -> Forecast? {
            w.map { Forecast.make(utilization: $0.utilization, resetsAt: $0.resetsAt, windowLength: len, now: now, schedule: schedule) }
        }
        let sets: [[StatusImage.Item]] = [
            [.init(label: "5H", forecast: fc(live?.fiveHour, LimitKind.fiveHour.length)),
             .init(label: "WK", forecast: fc(live?.week, LimitKind.week.length))],
            [.init(label: "5H", forecast: fc(LimitWindow(utilization: 41, resetsAt: now.addingTimeInterval(6780)), LimitKind.fiveHour.length)),
             .init(label: "WK", forecast: fc(LimitWindow(utilization: 71, resetsAt: now.addingTimeInterval(4.6 * 86400)), LimitKind.week.length))],
            [.init(label: "5H", forecast: fc(LimitWindow(utilization: 60, resetsAt: now.addingTimeInterval(3600)), LimitKind.fiveHour.length)),
             .init(label: "WK", forecast: fc(LimitWindow(utilization: 20, resetsAt: now.addingTimeInterval(4.6 * 86400)), LimitKind.week.length))],
        ]
        let images = BarStyle.allCases.flatMap { s in sets.map { StatusImage.make($0, now: now, style: s) } }
        let pad: CGFloat = 8, rowH = StatusImage.height, scale: CGFloat = 2
        let appearances = [NSAppearance(named: .aqua)!, NSAppearance(named: .darkAqua)!]
        let colW = (images.map(\.size.width).max() ?? 100) + pad * 2
        let w = colW * CGFloat(appearances.count)
        let h = (rowH + pad) * CGFloat(images.count) + pad

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (col, ap) in appearances.enumerated() {
            ap.performAsCurrentDrawingAppearance {
                let x0 = CGFloat(col) * colW
                NSColor.windowBackgroundColor.setFill()
                NSRect(x: x0, y: 0, width: colW, height: h).fill()
                var y = h - pad - rowH
                for img in images {
                    img.draw(at: NSPoint(x: x0 + pad, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                    y -= rowH + pad
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("widths:", BarStyle.allCases.map { s in "\(s.rawValue)=\(Int(StatusImage.make(sets[1], now: now, style: s).size.width))" })
    }
}

extension Preview {
    /// Renders the real popover view offscreen with sample data (no API calls, so it
    /// can't eat into the usage endpoint's rate limit): the Now tab on track and in
    /// warning/danger, then the Days, Weeks (squeezed and to scale) and 5h windows tabs.
    /// Light on top, dark below. With CLAUDE_METER_DATA_DIR set, it shows that folder's
    /// history instead; point it at a copy, since loading can prune or migrate it.
    static func renderPopover(to path: String) async {
        let real = ProcessInfo.processInfo.environment["CLAUDE_METER_DATA_DIR"] != nil
        let now = real ? Date() : SampleData.now()
        let demo = real ? Meter.load(now: now) : SampleData.meter(now: now)
        var hot = demo.history
        let last = hot.last
        hot.append(Sample(at: now, fiveHour: 60, week: 71,
                          fiveHourResetsAt: last?.fiveHourResetsAt, weekResetsAt: last?.weekResetsAt))
        let danger = Meter(config: demo.config, snapshot: UsageSnapshot(
            fiveHour: last?.fiveHourResetsAt.map { LimitWindow(utilization: 60, resetsAt: $0) },
            week: last?.weekResetsAt.map { LimitWindow(utilization: 71, resetsAt: $0) }, fetchedAt: now), history: hot)
        let shots: [(Meter, PopoverView.Tab, Bool)] = [(demo, .now, true), (danger, .now, true), (demo, .days, true),
                                                       (demo, .weeks, true), (demo, .weeks, false), (demo, .windows, true)]

        var rows: [[NSBitmapImageRep]] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var row: [NSBitmapImageRep] = []
            for (meter, tab, squeeze) in shots {
                let model = MeterModel(meter: meter)
                model.show(meter, at: now)
                model.tab = tab
                model.squeezeOffHours = squeeze
                let host = NSHostingView(rootView: PopoverView(model: model))
                let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 340, height: 600),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: name)
                window.contentView = host
                host.frame.size = host.fittingSize
                window.setContentSize(host.fittingSize)
                window.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    row.append(rep)
                }
                window.orderOut(nil)
            }
            rows.append(row)
        }

        let gap: CGFloat = 16
        let cellW = (rows.flatMap { $0 }.map(\.size.width).max() ?? 0) + gap
        let rowHs = rows.map { ($0.map(\.size.height).max() ?? 0) + gap }
        let w = cellW * CGFloat(shots.count) + gap
        let h = rowHs.reduce(gap, +)
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        var top = h - gap
        for (row, rowH) in zip(rows, rowHs) {
            for (i, rep) in row.enumerated() {
                rep.draw(in: NSRect(x: gap + CGFloat(i) * cellW, y: top - rep.size.height, width: rep.size.width, height: rep.size.height))
            }
            top -= rowH
        }
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
