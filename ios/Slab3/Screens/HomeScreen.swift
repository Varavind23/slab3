import SwiftUI
import SwiftData

/// Home (design.md §5): "Start Scanning" as the obvious primary action, recent
/// folders below to jump back into work in progress. Settings is a hamburger,
/// top-right — not a tab.
struct HomeScreen: View {
    let auth: AuthManager
    @Query(sort: \Folder.createdAt, order: .reverse) private var folders: [Folder]
    @Query private var cards: [Card]
    @State private var showSettings = false
    @State private var goScan = false

    private var recent: [Folder] { Array(folders.filter { !$0.archived }.prefix(5)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    NavigationLink(value: "scan") {
                        HStack {
                            Image(systemName: "barcode.viewfinder")
                            Text("Start Scanning").fontWeight(.semibold)
                            Spacer()
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Palette.surface2, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    HStack {
                        Text("\(cards.count) cards").font(.priceSmall)
                        Text("in inventory").slabLabel()
                    }

                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent folders").slabLabel()
                            ForEach(recent) { folder in
                                NavigationLink(value: folder.localId) {
                                    FolderSummaryRow(folder: folder)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Palette.bg)
            .navigationTitle("Slabs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "line.3.horizontal") }
                        .tint(Palette.textPrimary)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let f = folders.first(where: { $0.localId == id }) { FolderDetailScreen(folder: f) }
            }
            .navigationDestination(for: String.self) { _ in ScanScreen() }
            .sheet(isPresented: $showSettings) { SettingsSheet(auth: auth) }
        }
    }
}

struct FolderSummaryRow: View {
    let folder: Folder
    var body: some View {
        HStack {
            Image(systemName: "folder")
            Text(folder.name)
            Spacer()
            Text("\(folder.cards.count)").font(.priceSmall).foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border, lineWidth: 1))
        .opacity(folder.archived ? 0.5 : 1)
    }
}
