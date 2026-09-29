import Foundation

/// A group as the scan-target rules see it: which one, whether it is a lot's.
struct GroupRef: Equatable {
    let id: UUID
    let lotId: UUID?
    var archived = false

    init(id: UUID, lotId: UUID?, archived: Bool = false) {
        self.id = id; self.lotId = lotId; self.archived = archived
    }

    init(_ folder: Folder) {
        self.init(id: folder.localId, lotId: folder.teamLotId, archived: folder.archived)
    }
}

/// Which group new scans file into, decided in ONE place (teams-first plan, D4).
///
/// The Scan tab's target is also the team's "current lot" — Teams, the Scan bar
/// and Team activity all read it (CurrentLot) — so the rules that move it live
/// here, pure and tested, and run from MainShell when lots load, never in a view
/// body:
///   • resume: the stored target stays while it is still fileable;
///   • a lot's group is dropped once the lot has CLOSED (or gone) — but only after
///     this launch has loaded the lots: offline at a show, the local group is
///     trusted, or every scan would go to plain inventory unclaimed;
///   • with no target, a team member with exactly ONE open lot gets it picked for
///     them — unless they deliberately chose None, which is a real choice.
enum ScanTargetRule {
    static func resolve(stored: UUID?, explicitNone: Bool, groups: [GroupRef], lots: [Lot],
                        lotsLoaded: Bool, onTeam: Bool) -> UUID? {
        let open = Set(lots.filter { $0.status == .active }.map(\.id))
        if let stored, let group = groups.first(where: { $0.id == stored }), !group.archived {
            guard let lotId = group.lotId else { return stored }          // a plain group
            if !lotsLoaded || open.contains(lotId) { return stored }
        }
        guard onTeam, lotsLoaded, !explicitNone else { return nil }
        let lotGroups = groups.filter { g in !g.archived && g.lotId.map(open.contains) == true }
        return lotGroups.count == 1 ? lotGroups[0].id : nil
    }
}

/// The team's CURRENT lot: the open lot the Scan tab is filing into. Derived, never
/// stored — one source of truth (the scan target), so Teams and Scan cannot
/// disagree about which lot a buyer is working.
enum CurrentLot {
    static func resolve(scanTargetId: UUID?, groups: [GroupRef], lots: [Lot]) -> Lot? {
        guard let scanTargetId,
              let lotId = groups.first(where: { $0.id == scanTargetId })?.lotId else { return nil }
        return lots.first { $0.id == lotId && $0.status == .active }
    }
}
