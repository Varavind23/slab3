import SwiftUI

/// The inventory row — the densest component in the product and the one the whole
/// design is really about (reference/component-rules.md § CardRow).
///
/// Three lines on one square panel:
///   1. card name + the ACTIVE source's price, in that source's hue
///   2. the other two prices, the year/set metadata, and the confidence meter
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
    let source: PriceSource
    var selectable: Bool = false
    var selected: Bool = false

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
            PriceLead(prices: card.prices, source: source)
        }
    }

    // Line 2 — the other two prices, metadata, confidence.
    private var lineTwo: some View {
        HStack(alignment: .center, spacing: Caliper.space4) {
            PriceRest(prices: card.prices, source: source)
            Text("·").caliperMeta(Caliper.textTertiary)
            Text(card.metaLine).caliperMeta(Caliper.textTertiary).lineLimit(1)
            Spacer(minLength: Caliper.space3)
            ConfidenceMeter(value: card.confidences[source], source: source)
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
