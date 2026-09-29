import Testing
import Foundation
import SwiftData
@testable import Slab3

/// The lead's cold-launch split (reproduced in the Simulator 2026-09-28): `isLead`
/// flipped before the lots loaded, the group sync ran against an empty list, and
/// every lot group was detached — then duplicated empty. These pin the gate that
/// stops it and the repair that heals phones it already happened to.
@MainActor
struct LotGroupRepairTests {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Card.self, Folder.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func lot(_ name: String, id: UUID = UUID()) -> Lot {
        Lot(id: id, name: name, deadline: nil, status: .active, createdAt: Date())
    }

    private func card(_ cert: String, in folder: Folder?, lot: UUID?, _ context: ModelContext) -> Card {
        let card = Card(scan: CertScan(grader: .psa, certNumber: cert, raw: cert))
        context.insert(card)
        card.folder = folder
        card.lotClaimLotId = lot
        if lot != nil { card.lotClaimState = .confirmed }
        return card
    }

    private func folders(_ context: ModelContext) -> [Folder] {
        (try? context.fetch(FetchDescriptor<Folder>())) ?? []
    }

    // MARK: The gate

    @Test func aLeadFlipBeforeTheLotsLoadDoesNotSync() {
        let team = UUID()
        #expect(!TeamSync.shouldSyncGroups(teamLoadOK: true, teamId: team, lotsLoadedAt: nil, lotsTeamId: nil),
                "the launch value of `lots` is not this team's list")
        #expect(!TeamSync.shouldSyncGroups(teamLoadOK: true, teamId: team, lotsLoadedAt: Date(), lotsTeamId: UUID()),
                "another team's list is not this team's list")
        #expect(!TeamSync.shouldSyncGroups(teamLoadOK: false, teamId: team, lotsLoadedAt: Date(), lotsTeamId: team),
                "a failed team load proves nothing — no signal must never detach groups")
        #expect(TeamSync.shouldSyncGroups(teamLoadOK: true, teamId: team, lotsLoadedAt: Date(), lotsTeamId: team))
        #expect(TeamSync.shouldSyncGroups(teamLoadOK: true, teamId: nil, lotsLoadedAt: Date(), lotsTeamId: nil),
                "left the team, answer loaded: the groups may detach")
    }

    @Test func syncSaysWhichGroupsStoppedBeingLots() throws {
        let context = try makeContext()
        let gone = lot("Gone")
        LotFolders.sync([gone], isLead: true, in: context)
        let group = try #require(folders(context).first)
        _ = card("1", in: group, lot: gone.id, context)
        let released = LotFolders.sync([], isLead: true, in: context)
        #expect(released == [group.localId])
    }

    // MARK: The repair

    /// Exactly what the Simulator store looked like after one relaunch.
    @Test func repairReattachesTheSplitGroupAndDropsTheEmptyDuplicate() throws {
        let context = try makeContext()
        let weekend = lot("Weekend")
        let original = Folder(name: "Weekend")              // detached by the bug
        context.insert(original)
        _ = card("96679812", in: original, lot: weekend.id, context)
        let duplicate = Folder(name: "Weekend")             // made empty by the bug
        duplicate.teamLotId = weekend.id
        context.insert(duplicate)

        let report = LotFolders.repair([weekend], isLead: true, in: context)
        let left = folders(context)
        #expect(left.count == 1)
        #expect(left.first?.localId == original.localId, "the group holding the cards survives")
        #expect(left.first?.teamLotId == weekend.id, "and is the lot's group again")
        #expect(report.merged[duplicate.localId] == original.localId, "a scan target on the duplicate can follow")
    }

    @Test func repairMovesTheDuplicatesCardsAndQueuesTheUnclaimedOnes() throws {
        let context = try makeContext()
        let weekend = lot("Weekend")
        let original = Folder(name: "Weekend")
        context.insert(original)
        _ = card("1", in: original, lot: weekend.id, context)
        // Scanned after the split, into the PLAIN group: never claimed.
        let skipped = card("2", in: original, lot: nil, context)
        let duplicate = Folder(name: "Weekend")
        duplicate.teamLotId = weekend.id
        context.insert(duplicate)
        let claimedHere = card("3", in: duplicate, lot: weekend.id, context)

        let report = LotFolders.repair([weekend], isLead: true, in: context)
        #expect(claimedHere.folder?.localId == original.localId)
        #expect(claimedHere.lotClaimState == .confirmed, "a plain move — no release, no re-claim")
        #expect(skipped.lotClaimLotId == weekend.id)
        #expect(skipped.lotClaimState == .pending, "the skipped scan gets claimed now")
        #expect(report.requeued == 1)
    }

    @Test func repairIsIdempotentAndLeavesHealthyStoresAlone() throws {
        let context = try makeContext()
        let weekend = lot("Weekend")
        let original = Folder(name: "Weekend")
        context.insert(original)
        _ = card("1", in: original, lot: weekend.id, context)
        LotFolders.repair([weekend], isLead: true, in: context)
        let second = LotFolders.repair([weekend], isLead: true, in: context)
        #expect(second.isEmpty)
        #expect(folders(context).count == 1)

        // A plain group that merely shares a lot's name, with cards that were never
        // in the lot, is somebody's own group — never touched.
        let own = Folder(name: "Show")
        context.insert(own)
        _ = card("9", in: own, lot: nil, context)
        #expect(LotFolders.repair([lot("Show")], isLead: true, in: context).isEmpty)
        #expect(own.teamLotId == nil)
    }
}
