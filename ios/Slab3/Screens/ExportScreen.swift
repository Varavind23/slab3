import SwiftUI
import SwiftData

/// Export (README.md §6). Filter state is GLOBAL across tabs, so whatever scope
/// was set on Cards arrives here already applied — re-applying it would be the
/// bug. The filename encodes that scope and the date, because it is the only
/// label the buyer receives with the file.
struct ExportScreen: View {
    @Bindable var app: AppState
    /// A card inside its undo window has left the inventory as far as the user is
    /// concerned, so it must not appear in the file they hand a buyer either.
    let pendingDeletes: PendingDeletionStore
    @Query(sort: \Card.scannedAt, order: .reverse) private var allCards: [Card]
    @Query(sort: \Folder.createdAt, order: .reverse) private var groups: [Folder]

    @State private var showFilters = false
    @State private var shareURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                context: "\(filename) · \(scoped.count) rows",
                title: "Export",
                source: $app.activeSource
            )
            ScrollView {
                VStack(spacing: Caliper.rowGap) {
                    FilterPill(
                        label: filterLabel,
                        color: activeGroup?.hue,
                        isActive: app.filter != .all,
                        open: { showFilters = true },
                        clear: { app.filter = .all }
                    )
                    preview
                    columnPicker
                }
                .padding(.horizontal, Caliper.gutter)
                .padding(.bottom, Caliper.space8)
            }
            footer
        }
        .background(Caliper.bg)
        .sheet(isPresented: $showFilters) {
            FiltersSheet(app: app, cards: allCards, groups: groups, confirmVerb: "Export")
                .presentationDetents([.large])
        }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
    }

    // MARK: CSV preview

    /// A code window: title bar with the generated filename, then the header row
    /// and the first real rows. Header cells are tinted to the source that owns
    /// the column, which is what teaches the colour code in the file itself.
    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: Caliper.space4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Caliper.line).frame(width: 6, height: 6)
                }
                Text(filename).caliperMeta(Caliper.textSecondary)
                Spacer()
            }
            .padding(.horizontal, Caliper.rowPad)
            .padding(.vertical, Caliper.space4)
            Hairline()

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Caliper.space2) {
                    HStack(spacing: Caliper.space4) {
                        ForEach(app.enabledColumns) { column in
                            Text(column.header)
                                .font(.code)
                                .foregroundStyle(column.source?.hue ?? Caliper.textSecondary)
                        }
                    }
                    ForEach(previewRows, id: \.self) { row in
                        Text(row).font(.code).foregroundStyle(Caliper.textTertiary)
                    }
                    if scoped.isEmpty {
                        Text("no rows in this scope").font(.code).foregroundStyle(Caliper.textTertiary)
                    }
                }
                .padding(Caliper.rowPad)
            }
            .frame(height: 108, alignment: .topLeading)
        }
        .caliperPanel()
    }

    private var previewRows: [String] {
        Array(CSVExport.rows(Array(scoped.prefix(4)), columns: app.enabledColumns, payoutPercent: app.payoutPercent).dropFirst())
    }

    // MARK: Columns

    /// Selected chips carry a numeric order badge because selection order IS the
    /// column order in the file — the number has to be visible for that to be true.
    private var columnPicker: some View {
        VStack(alignment: .leading, spacing: Caliper.space5) {
            Text("Include columns").caliperLabel()
            // Fifteen small targets in a wrapping grid is the hardest thing on this
            // screen to hit, and they were drawn at the size of the row badge they
            // share a component with. The ink is now a step larger and each chip's
            // TARGET is the full 44 Caliper asks for — taller than the ink, so the
            // grid doesn't turn into fifteen buttons the size of Share CSV.
            FlowLayout(spacing: Caliper.space4) {
                ForEach(CSVColumn.allCases) { column in
                    let index = app.enabledColumns.firstIndex(of: column)
                    Button {
                        toggle(column)
                    } label: {
                        Chip(
                            text: column.label,
                            tone: index == nil ? .quiet : (column.source == nil ? .standard : .source),
                            color: column.source?.hue ?? Caliper.cyan,
                            order: index.map { $0 + 1 },
                            size: .tap
                        )
                        .frame(minHeight: Chip.Size.tap.hitHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CaliperPressStyle())
                    .accessibilityLabel(column.label)
                    .accessibilityValue(index.map { "Included, column \($0 + 1)" } ?? "Not included")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Caliper.space5)
    }

    private func toggle(_ column: CSVColumn) {
        if let i = app.enabledColumns.firstIndex(of: column) {
            app.enabledColumns.remove(at: i)
        } else {
            app.enabledColumns.append(column) // appended = last column in the file
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: Caliper.space5) {
            Hairline()
            HStack {
                Text("\(scoped.count) cards").caliperLabel()
                Spacer()
                Text(caliperMoney(cents: totalCents))
                    .font(.figureSmall)
                    .foregroundStyle(Caliper.textPrimary)
            }
            .padding(.horizontal, Caliper.gutter)

            CaliperButton(title: "Share CSV", variant: .primary, icon: "square.and.arrow.up", fullWidth: true,
                          disabled: scoped.isEmpty || app.enabledColumns.isEmpty) {
                shareURL = CSVExport.write(
                    scoped,
                    columns: app.enabledColumns,
                    scope: activeGroup?.name,
                    payoutPercent: app.payoutPercent
                )
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.bottom, Caliper.space4)
        }
        .background(Caliper.bg)
    }

    // MARK: Scope

    private var scoped: [Card] {
        allCards.filter { card in
            // A card in its undo window is gone from inventory, so it must not turn
            // up in the file a buyer receives either.
            guard !pendingDeletes.pendingIDs.contains(card.localId) else { return false }
            switch app.filter {
            case .all: return true
            case .ungrouped: return card.folder == nil
            case .unmatched: return !card.isMatched
            case .group(let id): return card.folder?.localId == id
            }
        }
    }
    private var totalCents: Int {
        scoped.compactMap { $0.prices.best(preferring: app.activeSource) }.reduce(0, +)
    }
    private var activeGroup: Folder? {
        if case .group(let id) = app.filter { return groups.first { $0.localId == id } }
        return nil
    }
    private var filterLabel: String {
        switch app.filter {
        case .all: return "All cards"
        case .ungrouped: return "Ungrouped"
        case .unmatched: return "Unmatched"
        case .group: return activeGroup?.name ?? "Group"
        }
    }
    private var filename: String { CSVExport.filename(scope: activeGroup?.name) }
}

/// Wrapping row layout for the column chips. iOS 17 has no built-in flow layout
/// and the chip grid must wrap on its own content widths, not a fixed column count.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += lineHeight + spacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// UIActivityViewController wrapper — hands the CSV to the OS share sheet. There
/// is no in-app file browser by design.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
