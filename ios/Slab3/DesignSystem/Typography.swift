import SwiftUI

/// Slabs typography (design.md §2). Numbers are the content: prices and grades
/// are bold with tabular figures so columns align and read cleanly at arm's
/// length in bad light. Labels recede; numbers dominate.
extension Font {
    /// The headline price number in a comparison — largest, boldest element.
    static let priceLarge = Font.system(size: 30, weight: .bold, design: .rounded).monospacedDigit()
    /// A secondary / muted price.
    static let priceSmall = Font.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit()
    /// Cert numbers and other fixed-width identifiers.
    static let mono = Font.system(.body, design: .monospaced)
}

extension Text {
    /// Muted secondary label styling (design.md: labels recede under numbers).
    func slabLabel() -> some View {
        self.font(.caption).foregroundStyle(Palette.textSecondary)
    }
}
