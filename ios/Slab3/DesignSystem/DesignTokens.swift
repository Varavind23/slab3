import SwiftUI

// Caliper design tokens — the Swift mirror of the design system's tokens/*.css.
// Generated from the design system, not hand-picked. If a value changes in CSS,
// change it here in the same commit.
//
// NOTE: this file replaced the old Palette.swift, which implemented design.md's
// "no accent color anywhere" rule. That rule has been deliberately overturned —
// Caliper is dark-only with cyan as the interface accent. See design.md, which now
// records the swap, and design/caliper/README.md for the system itself.

enum Caliper {

    // MARK: - Ground (dark only — there is no light variant)

    /// App background.
    static let bg = hex(0x06090C)
    /// Row / panel fill.
    static let surface = hex(0x0D1318)
    /// Chip and inset fill.
    static let surface2 = hex(0x141C22)
    /// Structural hairline.
    static let line = hex(0x1A242C)
    /// Control hairline — one step brighter than structure.
    static let lineStrong = hex(0x26333C)

    // MARK: - Ink

    static let textPrimary = hex(0xE8F1F4)
    static let textSecondary = hex(0x74858F)
    /// Cert numbers and dead metadata: present, never competing.
    static let textTertiary = hex(0x4A585F)
    /// Label color on a filled cyan control.
    static let textOnCyan = hex(0x04191A)

    // MARK: - Interface accent

    /// The scanner, the active state, and exactly ONE committed action per screen.
    /// Two cyan things on one screen means one of them is wrong.
    static let cyan = hex(0x35E0E8)
    static let cyanDim = hex(0x0E3A42)

    // MARK: - Price sources

    static let srcCL = hex(0x35E0E8)
    static let srcCY = hex(0x9BE85C)

    // MARK: - Confidence (deliberately warm, so a meter never reads as a source)

    static let confHigh = hex(0x62D69A)
    static let confMid = hex(0xE5B65C)
    static let confLow = hex(0xE0685E)

    static let payout = hex(0x62D69A)
    static let danger = hex(0xE0685E)

    // MARK: - Group tag hues (buyer identifiers; always beside the group's name)

    static let groupHues: [Color] = [
        hex(0xC98BFF), hex(0x9BE85C), hex(0x35E0E8),
        hex(0xE5B65C), hex(0xFF8FD0), hex(0x7FA6FF),
    ]

    /// Confidence 0–5 → its tone. 0–1 red, 2–3 amber, 4–5 green.
    static func confidence(_ value: Int) -> Color {
        value <= 1 ? confLow : value <= 3 ? confMid : confHigh
    }

    // MARK: - Spacing

    static let gutter: CGFloat = 18
    static let rowGap: CGFloat = 8
    static let rowPad: CGFloat = 12
    static let space1: CGFloat = 2
    static let space2: CGFloat = 4
    static let space3: CGFloat = 6
    static let space4: CGFloat = 8
    static let space5: CGFloat = 11
    static let space6: CGFloat = 14
    static let space7: CGFloat = 18
    static let space8: CGFloat = 24

    // MARK: - Geometry

    /// Square is the default. 3 is the MAXIMUM radius in the system and only
    /// controls get it. Panels and rows are not rounded.
    static let radiusControl: CGFloat = 3
    static let radiusPanel: CGFloat = 0
    static let borderWidth: CGFloat = 1
    static let hitMin: CGFloat = 44
    static let thumbSize = CGSize(width: 46, height: 64)

    // MARK: - Motion

    /// Sheets rise on this curve.
    static let easeOut = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.26)
    static let durFast: Double = 0.12
    /// How long the post-scan toast holds before it disappears.
    static let durToast: Double = 1.8

    static let pressedOpacity: Double = 0.6
    static let disabledOpacity: Double = 0.4

    private static func hex(_ v: UInt) -> Color {
        Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

/// The two price sources. Emphasis is global and persists across tabs; it changes
/// which price leads and what the list sorts by — it never hides the other source.
enum PriceSource: String, CaseIterable, Identifiable {
    case cl = "CL", cy = "CY"
    var id: String { rawValue }
    var hue: Color {
        switch self {
        case .cl: return Caliper.srcCL
        case .cy: return Caliper.srcCY
        }
    }
}

extension PriceSource {
    /// Spoken name — "CL" is unreadable to VoiceOver.
    var accessibilityName: String {
        switch self {
        case .cl: return "Card Ladder"
        case .cy: return "Courtyard"
        }
    }
}

/// The two prices for one card, in cents. A `nil` is a real answer — the source
/// has nothing — and renders as an em dash, never as zero.
struct PriceSet {
    var cl: Int?
    var cy: Int?

    subscript(_ source: PriceSource) -> Int? {
        switch source {
        case .cl: return cl
        case .cy: return cy
        }
    }

    /// The value a card counts for in a total: the active source when it has one,
    /// otherwise the best other quote we hold. A card with no quote counts zero
    /// and is excluded from "matched".
    func best(preferring source: PriceSource) -> Int? {
        self[source] ?? cl ?? cy
    }
}

/// Match confidence 0–5 per source. Same shape as PriceSet so the row can read
/// both with one index.
struct ConfidenceSet {
    var cl: Int = 0
    var cy: Int = 0

    subscript(_ source: PriceSource) -> Int {
        switch source {
        case .cl: return cl
        case .cy: return cy
        }
    }
}
