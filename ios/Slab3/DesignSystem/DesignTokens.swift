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

    /// Tone for a meter that is `lit` of `segments` full. Expressed as a fraction
    /// rather than a raw 0–5 because the meter is not always five wide: Courtyard
    /// draws three. The buckets are unchanged for a five-segment meter (0–1 red,
    /// 2–3 amber, 4–5 green) and land on low/medium/high for a three-segment one.
    static func confidence(_ lit: Int, of segments: Int) -> Color {
        let fraction = Double(lit) / Double(max(segments, 1))
        return fraction <= 0.34 ? confLow : fraction <= 0.7 ? confMid : confHigh
    }

    /// Whether a meter that full sits in the top band — the only state that blooms.
    static func isHighConfidence(_ lit: Int, of segments: Int) -> Bool {
        Double(lit) / Double(max(segments, 1)) > 0.7
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
    /// How many segments the confidence meter draws for this source.
    ///
    /// The precision the SOURCE actually asserts, not a house style. Card Ladder
    /// publishes a 1–5 confidence and its own UI shows five steps, so five is
    /// honest there. Courtyard's API carries a 1–5 too, but its app renders only
    /// low / medium / high beside the price — five segments would claim a
    /// resolution Courtyard never states, which is the price-fabrication rule
    /// applied to a match figure. Three segments say exactly what it says.
    var confidenceSegments: Int {
        switch self {
        case .cl: return 5
        case .cy: return 3
        }
    }

    /// A source's raw 0–5 confidence → how many segments light up. 0 stays 0: no
    /// basis for a match at all, and the detail screen hides the meter entirely.
    /// Courtyard buckets the way its own app does — 1 low, 2–3 medium, 4–5 high —
    /// which is the same split `Caliper.confidence(_:of:)` already colours by.
    func confidenceLevel(_ value: Int) -> Int {
        let v = min(max(value, 0), 5)
        switch self {
        case .cl: return v
        case .cy: return v == 0 ? 0 : v <= 1 ? 1 : v <= 3 ? 2 : 3
        }
    }

    /// Spoken name — "CL" is unreadable to VoiceOver.
    var accessibilityName: String {
        switch self {
        case .cl: return "Card Ladder"
        case .cy: return "Courtyard"
        }
    }
}

/// Which figure LEADS on a row, in the hero and in the sort: one of the two real
/// sources, or our own max-buy number (2026-09-22).
///
/// Deliberately NOT a third `PriceSource` case. `PriceSource` indexes data a source
/// actually stored — `PriceSet`, `ConfidenceSet`, `Card.sales(for:)`, and
/// `PriceRest`'s "every source except the active one". Max buy has no stored price,
/// no confidence and no comps of its own; it is computed from whatever comps a real
/// source left behind. A third case there would have compiled and then been quietly
/// wrong in ten binary `source == .cl ? … : …` ternaries — `Card.sales(for:)` would
/// have handed it Courtyard's comps by accident, and the row would have drawn two
/// trailing prices on line 2.
///
/// So the lens sits ABOVE the source: `AppState.activeSource` keeps its exact
/// meaning and every one of its read sites, and only the handful of places that
/// render a LEADING figure consult the lens.
enum PriceLens: String, CaseIterable, Identifiable {
    /// First, because it is the LEFTMOST segment on the toggle (owner, 2026-09-22).
    case maxBuy = "maxbuy"
    case cl = "CL", cy = "CY"

    var id: String { rawValue }

    /// The real source behind this lens, or nil for max buy — which is the whole
    /// distinction, so prefer branching on this over comparing cases.
    var source: PriceSource? {
        switch self {
        case .maxBuy: return nil
        case .cl: return .cl
        case .cy: return .cy
        }
    }

    init(_ source: PriceSource) {
        switch source {
        case .cl: self = .cl
        case .cy: self = .cy
        }
    }

    /// The toggle segment's ink. "MAX" rather than the full words because a segment
    /// is 30pt wide; the row and the hero spell it out where there is room.
    var label: String {
        switch self {
        case .maxBuy: return "MAX"
        case .cl: return "CL"
        case .cy: return "CY"
        }
    }

    /// Written out beside the figure it leads — the owner's call over the "VMB"
    /// acronym, and over a `VMB·CL` suffix naming the comps source, which would
    /// have put the evidence basis on a screen held out to the person being bought
    /// from.
    var rowLabel: String {
        switch self {
        case .maxBuy: return "MAX BUY"
        case .cl: return "CL"
        case .cy: return "CY"
        }
    }

    /// Per-segment width. The ONE place a longer label would be paid for, so a
    /// change here is the whole change — nothing else measures the toggle.
    var segmentWidth: CGFloat { 30 }

    /// Max buy takes `textPrimary`, never cyan: cyan is already Card Ladder's hue
    /// AND the screen's one primary action, and white is the register `MaxBuyPanel`
    /// uses to say the figure is ours rather than a source's.
    var hue: Color { source?.hue ?? Caliper.textPrimary }

    /// Spoken name — "MAX" and "CL" are both unreadable to VoiceOver.
    var accessibilityName: String {
        switch self {
        case .maxBuy: return "Max buy"
        case .cl, .cy: return source?.accessibilityName ?? ""
        }
    }

    /// "Max buy at claim" / "CL value at claim" — Team activity's labels, where
    /// every figure is one recorded when the slab was claimed.
    var atClaim: String { self == .maxBuy ? "Max buy at claim" : "\(label) value at claim" }

    /// The two real sources, in toggle order — for toggles where max buy has no
    /// meaning (which comps you are reading, a source's own figures).
    static let sources: [PriceLens] = [.cl, .cy]
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

/// Each source's own price confidence, 0–5. Same shape as PriceSet so the row can read
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
