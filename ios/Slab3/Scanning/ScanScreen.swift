import SwiftUI
import SwiftData

/// The scan tab: live camera scanner on top, a running list of what you just
/// scanned below. Each successful scan inserts a Card into the local store and
/// buzzes — designed for rattling through a stack of slabs at a show.
struct ScanScreen: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Card.scannedAt, order: .reverse) private var cards: [Card]

    @State private var lastScanned: [Card] = []
    @State private var banner: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScannerView { scan in handle(scan) }
                    .overlay(alignment: .top) { bannerView }

                sessionList
                    .frame(height: 220)
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var bannerView: some View {
        if let banner {
            Text(banner)
                .font(.callout.bold())
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var sessionList: some View {
        List {
            Section("This session (\(lastScanned.count))") {
                ForEach(lastScanned) { card in
                    HStack {
                        GraderChip(grader: card.grader)
                        VStack(alignment: .leading) {
                            Text(card.certNumber).monospaced().font(.body)
                            Text(card.lookupStatus == .pending ? "looking up…" : card.displaySubtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func handle(_ scan: CertScan) {
        // Skip if this exact cert is already in inventory.
        if cards.contains(where: { $0.grader == scan.grader && $0.certNumber == scan.certNumber }) {
            flash("Already scanned · \(scan.certNumber)")
            return
        }
        let card = Card(scan: scan)
        context.insert(card)
        lastScanned.insert(card, at: 0)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        flash("\(scan.grader.rawValue.uppercased()) · \(scan.certNumber)")
        // Fire the Courtyard price lookup — fills the price (and auto-identifies
        // the card if it's vaulted on Courtyard) without blocking the scan loop.
        Task { await PriceService.refresh(card, in: context) }
    }

    private func flash(_ text: String) {
        withAnimation { banner = text }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation { banner = nil }
        }
    }
}

/// Grayscale grader chip (design.md §1: structural elements are grayscale — no
/// color to signal identity; contrast and the label do the job).
struct GraderChip: View {
    let grader: Grader
    var body: some View {
        Text(grader.rawValue.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(Palette.textSecondary)
            .background(Palette.surface2)
            .clipShape(Capsule())
    }
}
