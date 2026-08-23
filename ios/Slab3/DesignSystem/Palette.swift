import SwiftUI
import UIKit

/// Slabs palette (design.md §1). No brand accent color anywhere — everything
/// structural is grayscale, and contrast + position (not color) signal
/// interactivity. Red/green are the ONLY saturated colors, reserved strictly
/// for price/judgment meaning. Both are softened, not stoplight-harsh; only the
/// positive green is expressive (it gets a glow), red stays flat and matte.
enum Palette {
    // MARK: Neutrals (dynamic light/dark)
    /// App background — near-white / near-black.
    static let bg = dyn(light: 0xFBFBFD, dark: 0x0A0A0B)
    /// Primary surface elevation (rows, cards).
    static let surface = dyn(light: 0xFFFFFF, dark: 0x16161A)
    /// Secondary elevation (chips, insets).
    static let surface2 = dyn(light: 0xF1F1F4, dark: 0x212128)
    static let border = dyn(light: 0xE4E4EA, dark: 0x2E2E37)
    static let textPrimary = dyn(light: 0x131316, dark: 0xF3F3F6)
    static let textSecondary = dyn(light: 0x70707A, dark: 0x9A9AA6)

    // MARK: Judgment colors (meaning only — never decorative)
    /// Winning / better price. Softened, desaturated — reads calm next to red.
    static let win = dyn(light: 0x2E8B57, dark: 0x4FB07C)
    /// Losing / worse price. Flat, matte — information to note, not a warning.
    static let lose = dyn(light: 0xB4554E, dark: 0xC46A63)

    private static func dyn(light: UInt, dark: UInt) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }
}

private extension UIColor {
    convenience init(rgb: UInt) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
