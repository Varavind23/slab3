import Testing
import Foundation
import SwiftData
@testable import Slab3

/// Archive and delete for lots and groups (owner, 2026-10-01;
/// ~/.claude/plans/misty-puzzling-nebula.md). The server's half — only a lead,
/// no deleting a lot with buys — is pinned in supabase/tests/lot_archive_test.sql.
@MainActor
struct ArchiveTests {

    let store: ModelContainer = try! ModelContainer(
        for: Card.self, Folder.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    private func freshApp(_ name: String = #function) -> AppState {
        let suite = "slabs.test.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppState(defaults: defaults)
    }

    private func lot(_ name: String, _ status: LotStatus = .closed, archived: Date? = nil) -> Lot {
        Lot(id: UUID(), name: name, deadline: nil, status: status, createdAt: Date(), archivedAt: archived)
    }

    private func card(in group: Folder?) -> Card {
        let c = Card(scan: CertScan(grader: .psa, certNumber: String(Int.random(in: 10_000_000...99_999_999)), raw: ""))
        c.folder = group
        store.mainContext.insert(c)
        return c
    }

    // ── Lots ──────────────────────────────────────────────────────────────────

    @Test func archivedLotsLeaveTheListsButNotTheGroupSync() {
        let open = lot("Open", .active), done = lot("Done", archived: Date())
        #expect(LotFolders.listed([open, done], isLead: true).map(\.name) == ["Open"])
        #expect(LotFolders.archived([open, done], isLead: false).map(\.name) == ["Done"])
        // `sync` reads `visible`: an archived lot must still be there, or its group
        // would be detached and every card in it would become a plain group's.
        #expect(LotFolders.visible([open, done], isLead: false).count == 2)
    }

    @Test func archivedNewestFirst() {
        let old = lot("Old", archived: Date(timeIntervalSince1970: 1_000)),
            new = lot("New", archived: Date(timeIntervalSince1970: 2_000))
        #expect(LotFolders.archived([old, new], isLead: true).map(\.name) == ["New", "Old"])
    }

    @Test func aLotDecodesWithOrWithoutArchivedAt() throws {
        let json = #"{"id":"6f1c2d3e-0000-4000-8000-000000000002","name":"Show","deadline":null,"status":"closed","banner":null,"created_at":"2026-10-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Lot.self, from: Data(json.utf8)).isArchived == false)
        let archived = json.replacingOccurrences(of: #""banner":null"#,
                                                 with: #""banner":null,"archived_at":"2026-10-02T00:00:00Z""#)
        #expect(try decoder.decode(Lot.self, from: Data(archived.utf8)).isArchived)
    }

    // ── Groups ────────────────────────────────────────────────────────────────

    @Test func archivingAGroupLetsGoOfIt() {
        let app = freshApp()
        let group = Folder(name: "consignment")
        store.mainContext.insert(group)
        let kept = card(in: group)
        app.scanTargetId = group.localId.uuidString
        app.filter = .group(group.localId)

        GroupActions.archive(group, app: app, in: store.mainContext)

        #expect(group.archived)
        #expect(app.scanTargetId.isEmpty, "scans stop filing into it")
        #expect(app.filter == .all, "and Cards stops showing a hidden group")
        #expect(kept.folder === group, "its cards keep their group")
        GroupActions.unarchive(group, in: store.mainContext)
        #expect(!group.archived)
    }

    @Test func deletingAGroupOnlyLeavesItsCardsUngrouped() throws {
        let app = freshApp()
        let group = Folder(name: "bulk cgc")
        store.mainContext.insert(group)
        let a = card(in: group), b = card(in: group)

        GroupActions.deleteKeepingCards(group, app: app, in: store.mainContext)

        #expect(try store.mainContext.fetch(FetchDescriptor<Folder>()).isEmpty)
        #expect(a.folder == nil && b.folder == nil)
        #expect(try store.mainContext.fetch(FetchDescriptor<Card>()).count == 2)
    }

    @Test func deletingAGroupWithItsCardsWaitsForTheUndoWindow() async throws {
        let app = freshApp()
        let pending = PendingDeletionStore(delay: .milliseconds(20))
        let group = Folder(name: "returns")
        store.mainContext.insert(group)
        _ = card(in: group); _ = card(in: group)

        GroupActions.deleteWithCards(group, app: app, pending: pending, in: store.mainContext)
        #expect(pending.pendingIDs.count == 2, "the cards vanish from view at once")
        #expect(try store.mainContext.fetch(FetchDescriptor<Folder>()).count == 1, "nothing is deleted yet")

        await pending.window?.value
        #expect(try store.mainContext.fetch(FetchDescriptor<Card>()).isEmpty)
        #expect(try store.mainContext.fetch(FetchDescriptor<Folder>()).isEmpty, "the group goes with them")
    }

    @Test func undoKeepsTheGroupAndItsCards() throws {
        let app = freshApp()
        let pending = PendingDeletionStore(delay: .seconds(60))
        let group = Folder(name: "returns")
        store.mainContext.insert(group)
        _ = card(in: group)

        GroupActions.deleteWithCards(group, app: app, pending: pending, in: store.mainContext)
        pending.undo()

        #expect(try store.mainContext.fetch(FetchDescriptor<Card>()).count == 1)
        #expect(group.cards.count == 1)
    }

    @Test func aLotsGroupIsNotTheUsersToManage() {
        let app = freshApp()
        let group = Folder(name: "Show 10/11")
        group.teamLotId = UUID()
        store.mainContext.insert(group)
        GroupActions.archive(group, app: app, in: store.mainContext)
        #expect(!group.archived, "LotFolders.sync owns it; the lead archives the LOT")
        #expect(!GroupActions.canManage(group))
    }
}
