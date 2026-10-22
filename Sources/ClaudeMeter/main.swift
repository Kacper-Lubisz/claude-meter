import AppKit
import MeterCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MeterModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    /// Style forced by config, or nil for auto.
    private lazy var pinnedStyle: BarStyle? = model.config.barStyle.flatMap(BarStyle.init(rawValue:))
    private var style: BarStyle = .full
    private var screensAsleep = false
    private var fitCheck: DispatchWorkItem?
    private var loggedStyle: BarStyle?

    func applicationDidFinishLaunching(_ note: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--preview-popover"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            Task { await Preview.renderPopover(to: path); NSApp.terminate(nil) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[i + 1]
            Task { await Preview.render(to: path, schedule: model.config.schedule); NSApp.terminate(nil) }
            return
        }

        style = pinnedStyle ?? .full
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        let nc = NotificationCenter.default, wnc = NSWorkspace.shared.notificationCenter
        // A display change can free up (or take away) menu bar room: start wide again.
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetFit() }
        }
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false; self?.resetFit() }
        }

        model.onChange = { [weak self] in self?.redraw() }
        redraw()
        model.start()
    }

    private func redraw() {
        let message: String? = model.snapshot == nil ? (model.error == nil ? "Claude…" : "Claude ⚠") : nil
        let items: [StatusImage.Item] = [.init(label: "5H", forecast: model.fiveHour),
                                         .init(label: "WK", forecast: model.week)]
        func image(_ s: BarStyle) -> NSImage { StatusImage.make(items, now: model.now, style: s, message: message) }

        // The item's right edge stays put as its width changes, so when it's currently
        // visible we can tell which styles would fit and take the widest, growing back
        // when room frees up. Otherwise fall back to stepping down after a check.
        if pinnedStyle == nil, let room = roomToLeftEdge {
            let fitting = BarStyle.allCases.first { image($0).size.width + 8 <= room } ?? .compact
            if fitting != style { log("room \(Int(room))pt: \(style.rawValue) -> \(fitting.rawValue)") }
            style = fitting
        }
        let img = image(style)
        statusItem.button?.image = img
        statusItem.length = img.size.width + 8
        statusItem.button?.toolTip = model.error?.localizedDescription ?? "Top: 5-hour window · Bottom: week"
        scheduleFitCheck()
    }

    // MARK: Fitting

    private func resetFit() {
        guard pinnedStyle == nil, statusItem != nil else { return }
        style = .full
        loggedStyle = nil
        redraw()
    }

    /// macOS hides status items that don't fit (e.g. behind the notch) by moving their
    /// window off screen. If that happened, step down to a narrower style.
    private func scheduleFitCheck() {
        guard pinnedStyle == nil else { return }
        fitCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.screensAsleep else { return }
                let frame = self.statusItem.button?.window?.frame ?? .zero
                let visible = self.isVisible
                guard !visible, let next = self.style.narrower else {
                    if self.loggedStyle != self.style {
                        log(visible ? "fits: \(self.style.rawValue) at \(frame)"
                                    : "still hidden at \(frame) with the narrowest style; free up menu bar space")
                        self.loggedStyle = self.style
                    }
                    return
                }
                log("hidden at \(frame) with \(self.style.rawValue); trying \(next.rawValue)")
                self.style = next
                self.redraw()
            }
        }
        fitCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Width available between the item's right edge and the notch (or screen edge),
    /// or nil if the item isn't visible now and its position can't be trusted.
    private var roomToLeftEdge: CGFloat? {
        guard isVisible, let w = statusItem.button?.window,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: w.frame.midX, y: w.frame.midY)) })
        else { return nil }
        let limit = screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX
        return w.frame.maxX - limit
    }

    private var isVisible: Bool {
        guard let w = statusItem.button?.window, w.occlusionState.contains(.visible),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: w.frame.midX, y: w.frame.midY)) })
        else { return false }
        // On a notched display an item can sit partly behind the notch while still
        // counting as on screen and visible, so check it against the notch's span.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           w.frame.maxX > left.maxX, w.frame.minX < right.minX {
            return false
        }
        return screen.frame.contains(w.frame)
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
            [.init(label: "5H", forecast: fc(live?.fiveHour, MeterModel.fiveHourLength)),
             .init(label: "WK", forecast: fc(live?.week, MeterModel.weekLength))],
            [.init(label: "5H", forecast: fc(LimitWindow(utilization: 41, resetsAt: now.addingTimeInterval(6780)), MeterModel.fiveHourLength)),
             .init(label: "WK", forecast: fc(LimitWindow(utilization: 71, resetsAt: now.addingTimeInterval(4.6 * 86400)), MeterModel.weekLength))],
            [.init(label: "5H", forecast: fc(LimitWindow(utilization: 60, resetsAt: now.addingTimeInterval(3600)), MeterModel.fiveHourLength)),
             .init(label: "WK", forecast: fc(LimitWindow(utilization: 20, resetsAt: now.addingTimeInterval(4.6 * 86400)), MeterModel.weekLength))],
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
    /// can't eat into the usage endpoint's rate limit): an on-track state and a
    /// warning/danger state, each in light and dark, side by side.
    static func renderPopover(to path: String) async {
        let now = Date()
        func model(five: Double, week: Double) -> MeterModel {
            let m = MeterModel()
            let fw = LimitWindow(utilization: five, resetsAt: now.addingTimeInterval(3600))
            let ww = LimitWindow(utilization: week, resetsAt: now.addingTimeInterval(4.6 * 86400))
            let start = ww.resetsAt.addingTimeInterval(-MeterModel.weekLength)
            let samples = stride(from: 0.0, through: 1.0, by: 0.05).map { t in
                Sample(at: start.addingTimeInterval(t * now.timeIntervalSince(start)),
                       fiveHour: t > 0.8 ? five * (t - 0.8) / 0.2 : nil, week: week * t)
            }
            m.show(UsageSnapshot(fiveHour: fw, week: ww, fetchedAt: now), history: samples)
            return m
        }

        var shots: [NSBitmapImageRep] = []
        for model in [model(five: 20, week: 12), model(five: 60, week: 71)] {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
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
                    shots.append(rep)
                }
                window.orderOut(nil)
            }
        }

        let gap: CGFloat = 16
        let w = shots.reduce(0) { $0 + $1.size.width } + gap * CGFloat(shots.count + 1)
        let h = (shots.map(\.size.height).max() ?? 0) + gap * 2
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        var x = gap
        for rep in shots {
            rep.draw(in: NSRect(x: x, y: h - gap - rep.size.height, width: rep.size.width, height: rep.size.height))
            x += rep.size.width + gap
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
