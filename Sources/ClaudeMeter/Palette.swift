import AppKit
import MeterCore
import SwiftUI

/// Popover colours. The stock system colours (.green, .orange, .secondary) are too
/// pale on light backgrounds and depend on whatever shows through the popover's
/// translucent material, so the popover paints its own background and uses these.
/// Every text colour is at least 4.5:1 against `background` (most are 7:1+).
enum Palette {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let background = dynamic(light: 0xF7F7F8, dark: 0x1E1E21)
    static let text       = dynamic(light: 0x18181B, dark: 0xF4F4F5) // ~16:1
    static let muted      = dynamic(light: 0x4B4B55, dark: 0xB8B8C2) // ~8:1
    static let hairline   = dynamic(light: 0xD4D4DA, dark: 0x3C3C44)
    static let track      = dynamic(light: 0xE2E2E7, dark: 0x34343B)
    /// Working hours behind a chart's lines.
    static let band       = dynamic(light: 0xE9E9EE, dark: 0x2C2C32)
    static let accent     = dynamic(light: 0x0A5CC2, dark: 0x6EADFF) // ~6:1 / ~7:1
    static let ok         = dynamic(light: 0x17784A, dark: 0x4ADE80) // ~5.3:1 / ~10:1
    static let warn       = dynamic(light: 0xA14A00, dark: 0xFDB54A) // ~5.6:1 / ~10:1
    static let bad        = dynamic(light: 0xC0221F, dark: 0xFF7C72) // ~5.8:1 / ~6.6:1

    static func status(_ s: PaceStatus) -> Color {
        switch s { case .ok: ok; case .warn: warn; case .over: bad }
    }

    /// Bar and chart fill: the accent while on track, the alert colour otherwise.
    static func fill(_ s: PaceStatus) -> Color { s == .ok ? accent : status(s) }
}
