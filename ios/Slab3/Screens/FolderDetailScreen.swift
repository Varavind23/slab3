import SwiftUI
import SwiftData

/// A folder's cards with the two market prices, plus CSV export (design.md §5,
/// §6). The 4th identical card+grade shows a soft, non-blocking inline notice.
struct FolderDetailScreen: View {
    @Bindable var folder: Folder
    @Environment(\.modelContext) private var context
    @State private var exporting = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            if folder.cards.isEmpty {
                Text("No cards yet. Assign cards from Unsorted.").slabLabel()
            }
            ForEach(folder.cards.sorted(by: { $0.scannedAt > $1.scannedAt })) { card in
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink(value: card.localId) { CardPriceRow(card: card) }
                    // Soft sale-limit notice — 4th+ identical card+grade (design.md §5).
                    if folder.identicalCount(cardKey: card.cardKey) > 3 {
                        Text("4th of this card + grade in this folder.")
                            .font(.caption).foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
        .background(Palette.bg)
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Export CSV") { exportURL = CSVExport.write(folder: folder); exporting = exportURL != nil }
                    Button(folder.archived ? "Unarchive" : "Archive") { folder.archived.toggle() }
                } label: { Image(systemName: "ellipsis.circle") }
                .tint(Palette.textPrimary)
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let c = folder.cards.first(where: { $0.localId == id }) { CardDetailScreen(card: c) }
        }
        .sheet(isPresented: $exporting) {
            if let url = exportURL { ShareSheet(items: [url]) }
        }
    }
}

/// Folder row (design.md §6): grade chip, card name, and the two prices with
/// the winner treatment. No thumbnails (deliberately dropped).
struct CardPriceRow: View {
    let card: Card
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.displayTitle).font(.body).lineLimit(1)
                GradeChip(grader: card.grader, grade: card.grade)
            }
            Spacer(minLength: 8)
            PricePair(
                courtyardCents: card.courtyardPriceCents ?? card.manualPriceCents,
                cardLadderCents: card.cardLadderPriceCents,
                loading: card.pricesLoading
            )
        }
        .padding(.vertical, 4)
    }
}

/// Grayscale grade/grader chip (design.md §1: structural = grayscale, not color).
struct GradeChip: View {
    let grader: Grader
    let grade: String?
    var body: some View {
        Text("\(grader.rawValue.uppercased()) \(grade ?? "—")")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(Palette.textSecondary)
            .background(Palette.surface2, in: Capsule())
    }
}

/// UIActivityViewController wrapper for CSV export.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
