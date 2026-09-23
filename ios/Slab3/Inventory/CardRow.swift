import SwiftUI

/// The inventory row — the densest component in the product and the one the whole
/// design is really about (reference/component-rules.md § CardRow).
///
/// Three lines on one square panel:
///   1. card name + the LEADING figure — the active source's price in its own hue,
///      or our own max-buy number when that lens is on
///   2. the price(s) that aren't leading, the year/set metadata, and the
///      confidence meter
///   3. the cert, the group chip, and the grade badge
///
/// What must not be lost: both sources stay visible whichever one leads; a
/// missing price is an em dash; the thumbnail never disappears, because a photo of
/// the slab is how a sourcer recognises what they scanned.
///
/// Selection is `selectable` + `selected` on this same row — not a different
/// component and not a different screen, so the list never reflows.
struct CardRow: View {
    let card: Card
    /// Which figure leads. Under `.maxBuy` no real source leads, so line 1 becomes
    /// our own number and line 2 carries BOTH sources — the rule that every source
    /// stays visible on every row is what the lens must not break.
    let lens: PriceLens
    var selectable: Bool = false
    var selected: Bool = false

    /// The source underneath the lens, for the parts of the row that are still
    /// per-source. Max buy has none, and those parts branch rather than guess.
    private var source: PriceSource? { lens.source }

    var body: some View {
        HStack(alignment: .top, spacing: Caliper.rowPad) {
            if selectable { selectionCircle }
            SlabThumbnail(card: card)
            VStack(alignment: .leading, spacing: Caliper.space3) {
                lineOne
                lineTwo
                lineThree
            }
        }
        .padding(Caliper.rowPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .caliperPanel(selected: selected)
    }

    // Line 1 — name and the leading price.
    private var lineOne: some View {
        HStack(alignment: .firstTextBaseline, spacing: Caliper.space4) {
            Text(card.displayTitle)
                .font(.calBody)
                .foregroundStyle(Caliper.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Caliper.space3)
            if let source {
                PriceLead(prices: card.prices, source: source)
            } else {
                MaxBuyLead(cents: MaxBuyValue.cents(for: card))
            }
        }
    }

    // Line 2 — the trailing price(s), metadata, confidence.
    private var lineTwo: some View {
        HStack(alignment: .center, spacing: Caliper.space4) {
            // Under max buy this shows both sources rather than one, which costs
            // metaLine some of its truncation budget — the most expendable thing on
            // the row, and already truncating.
            PriceRest(prices: card.prices, source: source ?? .cl,
                      showing: source == nil ? PriceSource.allCases : nil)
            Text("·").caliperMeta(Caliper.textTertiary)
            Text(card.metaLine).caliperMeta(Caliper.textTertiary).lineLimit(1)
            Spacer(minLength: Caliper.space3)
            trailingMeter
        }
    }

    /// The confidence slot, always `ConfidenceMeter.totalWidth` wide so the row's
    /// right edge never moves when the toggle flips.
    ///
    /// Under max buy it is EMPTY. A confidence meter belongs to a source — it grades
    /// how sure we are of the match, not of our own arithmetic — and borrowing the
    /// comps source's meter would also leak which source answered, since CL draws
    /// five segments and CY three. The blank keeps the geometry and claims nothing.
    @ViewBuilder
    private var trailingMeter: some View {
        if let source {
            ConfidenceMeter(value: card.confidences[source], source: source)
        } else {
            Color.clear.frame(width: ConfidenceMeter.totalWidth, height: 4)
        }
    }

    // Line 3 — cert, group, grade.
    private var lineThree: some View {
        HStack(spacing: Caliper.space4) {
            Text("#\(card.certNumber)").caliperMeta(Caliper.textTertiary)
            Spacer(minLength: Caliper.space3)
            if let folder = card.folder {
                GroupTag(name: folder.name, color: folder.hue)
            }
            GradeBadge(grader: card.grader, grade: card.grade)
        }
    }

    /// 19pt circle, filled cyan with a check when selected. Present only in
    /// selection mode, and its appearance must not move anything else.
    private var selectionCircle: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? Color.clear : Caliper.lineStrong, lineWidth: Caliper.borderWidth)
                .background(Circle().fill(selected ? Caliper.cyan : Color.clear))
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Caliper.textOnCyan)
            }
        }
        .frame(width: 19, height: 19)
        .padding(.top, Caliper.space5)
    }
}

/// 46 × 64 photo of the physical slab. Until the scanner captures one, a hairline
/// placeholder carrying the grader holds the position — the row must never lose
/// the thumbnail, because its absence is what makes a list of certs unreadable.
struct SlabThumbnail: View {
    let card: Card

    var body: some View {
        Group {
            if let data = card.thumbnailData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                SlabPlaceholder(card: card)
            }
        }
        .frame(width: Caliper.thumbSize.width, height: Caliper.thumbSize.height)
        .clipped()
        .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
        .accessibilityHidden(true)
    }
}

/// What stands in when a card has no picture at all. Shared by the row thumbnail
/// and the detail screen so the two never drift into looking like different apps.
struct SlabPlaceholder: View {
    let card: Card
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Caliper.surface2
            VStack(spacing: Caliper.space1 * scale) {
                Text(card.grader.rawValue.uppercased())
                    .font(.mono(8 * scale, .medium))
                    .foregroundStyle(Caliper.textTertiary)
                Text(card.grade ?? "—")
                    .font(.mono(11 * scale, .bold))
                    .foregroundStyle(Caliper.textSecondary)
            }
        }
    }
}
