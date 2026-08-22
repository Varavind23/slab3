import SwiftUI
import SwiftData

/// All scanned cards, newest first. Search filters by cert / name / set.
struct InventoryScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Card.scannedAt, order: .reverse) private var cards: [Card]
    @State private var search = ""

    private var filtered: [Card] {
        guard !search.isEmpty else { return cards }
        let q = search.lowercased()
        return cards.filter {
            $0.certNumber.contains(q)
                || ($0.name?.lowercased().contains(q) ?? false)
                || ($0.set?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if cards.isEmpty {
                    ContentUnavailableView(
                        "No cards yet",
                        systemImage: "barcode.viewfinder",
                        description: Text("Scan a PSA or CGC slab to start your inventory.")
                    )
                } else {
                    List {
                        ForEach(filtered) { card in
                            NavigationLink(value: card.localId) {
                                CardRow(card: card)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .searchable(text: $search, prompt: "Cert, card, or set")
                }
            }
            .navigationTitle("Inventory (\(cards.count))")
            .navigationDestination(for: UUID.self) { id in
                if let card = cards.first(where: { $0.localId == id }) {
                    CardDetailScreen(card: card)
                }
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for i in offsets { context.delete(filtered[i]) }
    }
}

struct CardRow: View {
    let card: Card
    var body: some View {
        HStack(spacing: 10) {
            GraderChip(grader: card.grader)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.displayTitle).font(.body)
                Text(card.displaySubtitle.isEmpty ? card.certNumber : card.displaySubtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if card.lookupStatus == .pending {
                Image(systemName: "clock").foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}
