import SwiftUI
import SwiftData

/// Folders (design.md §5): "Unsorted" pinned at top (cards not yet assigned —
/// not a folder, can't export the same way), then the user's folders. Archived
/// folders demoted to the bottom.
struct FoldersScreen: View {
    let auth: AuthManager
    @Environment(\.modelContext) private var context
    @Query(sort: \Folder.createdAt, order: .reverse) private var folders: [Folder]
    @Query private var allCards: [Card]
    @State private var showSettings = false
    @State private var newFolderName = ""
    @State private var creating = false

    private var unsorted: [Card] { allCards.filter { $0.folder == nil } }
    private var active: [Folder] { folders.filter { !$0.archived } }
    private var archived: [Folder] { folders.filter { $0.archived } }

    init(auth: AuthManager) { self.auth = auth }

    var body: some View {
        NavigationStack {
            List {
                if !unsorted.isEmpty {
                    Section {
                        NavigationLink(value: "unsorted") {
                            HStack {
                                Image(systemName: "tray")
                                Text("Unsorted")
                                Spacer()
                                Text("\(unsorted.count)").foregroundStyle(Palette.textSecondary)
                            }
                        }
                    }
                }
                Section("Folders") {
                    ForEach(active) { f in
                        NavigationLink(value: f.localId) { FolderSummaryRow(folder: f) }
                    }
                    .onDelete { idx in idx.map { active[$0] }.forEach(context.delete) }
                    if active.isEmpty {
                        Text("No folders yet. Start a scan to build one.").slabLabel()
                    }
                }
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { f in
                            NavigationLink(value: f.localId) { FolderSummaryRow(folder: f) }
                        }
                    }
                }
            }
            .background(Palette.bg)
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "line.3.horizontal") }
                        .tint(Palette.textPrimary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .tint(Palette.textPrimary)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let f = folders.first(where: { $0.localId == id }) { FolderDetailScreen(folder: f) }
            }
            .navigationDestination(for: String.self) { _ in UnsortedScreen() }
            .sheet(isPresented: $showSettings) { SettingsSheet(auth: auth) }
            .alert("New folder", isPresented: $creating) {
                TextField("Name", text: $newFolderName)
                Button("Create") { createFolder() }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        context.insert(Folder(name: name))
        newFolderName = ""
    }
}

/// Unsorted cards (design.md §5) — same rows as a folder, but no export.
struct UnsortedScreen: View {
    @Query private var allCards: [Card]
    private var unsorted: [Card] { allCards.filter { $0.folder == nil } }

    var body: some View {
        List(unsorted) { card in
            NavigationLink(value: card.localId) { CardPriceRow(card: card) }
        }
        .navigationTitle("Unsorted")
        .navigationDestination(for: UUID.self) { id in
            if let c = unsorted.first(where: { $0.localId == id }) { CardDetailScreen(card: c) }
        }
    }
}
