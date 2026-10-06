import Foundation
import SwiftData

/// The ONE place a card's group changes (teams plan §2).
///
/// Six places file or un-file cards — the scan's filing bar, the Cards swipe, the
/// row's context menu, the selection bar, the group sheet and the detail screen.
/// They used to each write `card.folder` themselves, and each had to remember the
/// `markUsed` rule beside it (CLAUDE.md, `Folder.lastUsedAt`). Teams makes a third
/// rule that none of them may forget: filing into a TEAM LOT claims a slot on the
/// server, and leaving one releases it (phase 4). A rule six call sites must each
/// remember is a rule one of them forgets, and the one that forgets it is a card in
/// a lot that skipped the 3-per-lot check. So they all come through here.
///
/// One exception: deleting a group (`GroupActions`) ungroups its cards through the
/// relationship's `.nullify`. Safe only because team lots can never be deleted there.
@MainActor
enum CardFiling {
    /// File `cards` into `group`. Recency is recorded here, so the Cards swipe
    /// keeps offering the group last used.
    ///
    /// Teams (phase 4): a card LEAVING a lot for this group gives its slot back,
    /// and a card entering a lot group is claimed. The claim runs after this
    /// returns — the card is in the group now and shows "Checking lot…" until the
    /// server answers; a block moves it back out (LotClaims.apply). Claims go through
    /// LotClaimQueue, one at a time, so a bulk file never bursts Card Ladder.
    static func file(_ cards: [Card], into group: Folder, in context: ModelContext, at time: Date = Date()) {
        guard !cards.isEmpty else { return }
        for card in cards where card.folder?.localId != group.localId { releaseSlot(of: card) }
        for card in cards { card.folder = group }
        group.markUsed(at: time)
        try? context.save()

        // Kill switch: a lot group files like any other group, and no card is left
        // saying "Checking lot…" for a claim that will never be sent.
        guard TeamsFeature.isAvailable, let lotId = group.teamLotId else { return }
        for card in cards where needsClaim(card, lotId: lotId) {
            // Filed straight back into the lot it just left: a release still
            // waiting for signal would land first (releases go first on reconnect)
            // and give the slot away. Cancelled, the claim replays the held one.
            PendingReleaseStore.shared.cancel(lotId: lotId, cert: card.certNumber, grader: card.grader.rawValue)
            card.lotClaimLotId = lotId
            card.lotClaimState = .checking
            LotClaimQueue.shared.enqueue(.claim(cardId: card.localId, lotId: lotId, rangeId: nil), in: context)
        }
        try? context.save()
    }

    /// Take `cards` out of whatever group they are in. Un-filing is deliberately
    /// NOT recency: it must not make the swipe offer the group just left. Leaving a
    /// lot gives the slot back.
    static func unfile(_ cards: [Card], in context: ModelContext) {
        let filed = cards.filter { $0.folder != nil }
        guard !filed.isEmpty else { return }
        for card in filed {
            releaseSlot(of: card)
            card.folder = nil
        }
        try? context.save()
    }

    /// Already claimed (or being claimed) into this lot: nothing to ask.
    private static func needsClaim(_ card: Card, lotId: UUID) -> Bool {
        guard card.lotClaimLotId == lotId else { return true }
        switch card.lotClaimState {
        case .confirmed, .overLimit, .checking: return false
        default: return true
        }
    }

    /// Hand back a card's lot slot, and forget the lot state either way — a card
    /// that leaves a lot has nothing left to say about it.
    private static func releaseSlot(of card: Card) {
        guard let lotId = card.lotClaimLotId else { return }
        if card.mayHoldLotSlot {
            LotClaims.queueRelease(lotId: lotId, cert: card.certNumber, grader: card.grader)
        }
        card.lotClaimLotId = nil
        card.lotClaimState = nil
        card.lotVerdict = nil
    }

    /// The detail screen's group row is a toggle: tapping the current group leaves it.
    static func toggle(_ card: Card, group: Folder, in context: ModelContext) {
        if card.folder?.localId == group.localId {
            unfile([card], in: context)
        } else {
            file([card], into: group, in: context)
        }
    }
}
