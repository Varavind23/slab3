import SwiftUI
import UIKit

// Caliper typography — the Swift mirror of tokens/typography.css.
// REPLACES Slab3/DesignSystem/Typography.swift.
//
// Two faces: Space Grotesk carries voice, JetBrains Mono carries every number and
// label. Both are Google Fonts, and the design system loads them over the web —
// there are no .ttf binaries in the handoff bundle. Until they're added to the
// target and registered under UIAppFonts, `sans`/`mono` fall back to the system
// faces at the SAME sizes and weights, so every measurement in this file is still
// honoured. The fallback is explicit rather than silent: `Font.custom` with a
// missing name quietly resolves to the system font, which hides the fact that the
// type isn't the designed type.
//
// Every figure is tabular so prices, certs and counts align down a scrolling list.
// Titles are deliberately SMALL: the money should be the biggest thing on screen,
// not the word "Inventory".

extension Font {

    // MARK: - Faces

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let name = "SpaceGrotesk-" + psName(weight)
        guard CaliperFonts.isRegistered(name) else {
            return .system(size: size, weight: weight)
        }
        return .custom(name, size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let name = "JetBrainsMono-" + psName(weight)
        guard CaliperFonts.isRegistered(name) else {
            return .system(size: size, weight: weight, design: .monospaced).monospacedDigit()
        }
        return .custom(name, size: size).weight(weight).monospacedDigit()
    }

    // MARK: - Figures — the one hero number per screen

    /// Estimated / group total. 31/700.
    static let figure = sans(31, .bold).monospacedDigit()
    /// Est. payout, selection total. 17/700.
    static let figureSmall = sans(17, .bold).monospacedDigit()

    // MARK: - Titles

    /// Page title. 23/600 — NOT a large title.
    static let calTitle = sans(23, .semibold)
    /// Sheet title. 16/600.
    static let calHeading = sans(16, .semibold)

    // MARK: - Body

    /// Card names, sheet rows. 13/500.
    static let calBody = sans(13, .medium)
    static let calBodySmall = sans(12, .medium)

    // MARK: - Mono registers — the workhorses

    /// A price on a row. 11/500.
    static let price = mono(11, .medium)
    /// A completed sale in the comps list. 15/600 — deliberately larger than
    /// `price`, because these are the numbers a reseller reads one after another
    /// to pick a figure, not a value glanced at in a dense row.
    static let saleFigure = mono(15, .semibold)
    /// Year, set, cert, the trailing two prices. 9/500.
    static let meta = mono(9, .medium)
    /// Uppercase tracked label: EST. PAYOUT, 3 SELECTED. 10/500.
    static let label = mono(10, .medium)
    /// The CSV preview. 9/400.
    static let code = mono(9, .regular)

    private static func psName(_ w: Font.Weight) -> String {
        switch w {
        case .bold: return "Bold"
        case .semibold: return "SemiBold"
        case .regular: return "Regular"
        default: return "Medium"
        }
    }
}

/// Whether the designed faces are actually installed. Checked once per name —
/// `UIFont(name:)` is not free, and these run on every row of a scrolling list.
enum CaliperFonts {
    /// True once the .ttf files are in the target and listed under UIAppFonts.
    static var areInstalled: Bool { isRegistered("SpaceGrotesk-Medium") }

    private static var cache: [String: Bool] = [:]

    static func isRegistered(_ name: String) -> Bool {
        if let known = cache[name] { return known }
        let found = UIFont(name: name, size: 12) != nil
        cache[name] = found
        return found
    }
}

extension View {
    /// Mono labels are uppercase with wide tracking. Use this; don't retype the values.
    func caliperLabel(_ color: Color = Caliper.textSecondary) -> some View {
        self.font(.label).tracking(1.3).textCase(.uppercase).foregroundStyle(color)
    }

    /// Metadata line: mono 9, light tracking, secondary ink.
    func caliperMeta(_ color: Color = Caliper.textSecondary) -> some View {
        self.font(.meta).tracking(0.45).foregroundStyle(color)
    }

    /// A panel: surface fill, hairline border, square corners, NO shadow.
    func caliperPanel(selected: Bool = false) -> some View {
        self
            .background(selected ? Caliper.cyan.opacity(0.055) : Caliper.surface)
            .overlay(
                Rectangle().strokeBorder(
                    selected ? Caliper.cyanDim : Caliper.line,
                    lineWidth: Caliper.borderWidth
                )
            )
    }

    /// The ONE glow in the system. Allowed on the scanline, an active toggle segment,
    /// and a fresh capture's readout. Nothing else.
    func caliperGlow(_ color: Color = Caliper.cyan) -> some View {
        self.shadow(color: color.opacity(0.55), radius: 8)
    }
}

/// Formats money the way the whole product does: comma separated, to the CENT.
/// A missing value is an em dash — NEVER "$0" and never blank.
///
/// Cents, not whole dollars (owner decision 2026-08-31). This used to round,
/// on the reasoning that whole dollars are the only precision a sourcer reads at
/// arm's length. But both sources state their number to the cent — Courtyard's
/// own app shows $50.80 for cert 96679812 — and rounding it made our figure
/// disagree with theirs on the same slab, which is exactly the doubt this app
/// exists to remove. Displaying what the source said is worth more than the
/// glanceability.
func caliperMoney(_ dollars: Int?) -> String {
    guard let dollars else { return "—" }
    return dollars.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
        .withDollarPrefix()
}

/// The money formatter, from the integer cents the store actually keeps.
func caliperMoney(cents: Int?) -> String {
    guard let cents else { return "—" }
    return (Double(cents) / 100)
        .formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
        .withDollarPrefix()
}

private extension String {
    func withDollarPrefix() -> String { "$" + self }
}
