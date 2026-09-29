import Testing
import Foundation
import SwiftData
@testable import Slab3

/// Releases that must survive no signal, and claims that must never burst
/// (teams-first plan, phase 0).
@MainActor
struct LotClaimQueueTests {

    private func scratchDefaults() -> UserDefaults {
        let suite = "LotClaimQueueTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func release(_ cert: String, lot: UUID = UUID()) -> PendingRelease {
        PendingRelease(lotId: lot, cert: cert, grader: "psa")
    }

    // MARK: PendingReleaseStore

    @Test func aQueuedReleaseSurvivesARelaunch() {
        let defaults = scratchDefaults()
        let r = release("96679812")
        PendingReleaseStore(defaults: defaults).add(r)
        #expect(PendingReleaseStore(defaults: defaults).all.map(\.key) == [r.key],
                "a fresh store — a relaunch — still has it")
    }

    @Test func oneSlabIsOneRelease() {
        let store = PendingReleaseStore(defaults: scratchDefaults())
        let lot = UUID()
        store.add(release("1", lot: lot))
        store.add(release("1", lot: lot))
        store.add(release("1"))                  // same cert, another lot
        #expect(store.all.count == 2)
    }

    @Test func claimingItBackCancelsTheRelease() {
        let store = PendingReleaseStore(defaults: scratchDefaults())
        let lot = UUID()
        store.add(release("1", lot: lot))
        store.cancel(lotId: lot, cert: "1", grader: "psa")
        #expect(store.all.isEmpty)
    }

    // MARK: ReleaseOutcome

    @Test func onlyAnAnswerFinishesARelease() {
        #expect(ReleaseOutcome.classify(outcome: "released", errorCode: nil) == .done)
        #expect(ReleaseOutcome.classify(outcome: "not_claimed", errorCode: nil) == .done,
                "already released (a replay) is done, not an error")
        #expect(ReleaseOutcome.classify(outcome: nil, errorCode: "not_member") == .done,
                "off the team: no retry will ever change it")
        #expect(ReleaseOutcome.classify(outcome: nil, errorCode: "not_lead") == .done)
        #expect(ReleaseOutcome.classify(outcome: nil, errorCode: nil) == .retry, "no signal")
        #expect(ReleaseOutcome.classify(outcome: nil, errorCode: "not_authenticated") == .retry)
    }

    // MARK: LotClaimQueue

    private func recordingQueue() -> (LotClaimQueue, () -> [LotClaimQueue.Op], () -> Int) {
        let queue = LotClaimQueue()
        var ran: [LotClaimQueue.Op] = []
        var running = 0, peak = 0
        queue.perform = { op, _ in
            running += 1; peak = max(peak, running)
            try? await Task.sleep(for: .milliseconds(5))
            ran.append(op)
            running -= 1
        }
        return (queue, { ran }, { peak })
    }

    @Test func opsRunOneAtATimeInOrder() async {
        let (queue, ran, peak) = recordingQueue()
        let ops = (0..<5).map { _ in LotClaimQueue.Op.claim(cardId: UUID(), lotId: UUID(), rangeId: nil) }
        ops.forEach { queue.enqueue($0) }
        await queue.drain()
        #expect(ran() == ops)
        #expect(peak() == 1, "never two requests in flight")
        #expect(queue.isIdle)
    }

    @Test func aCardQueuedTwiceIsClaimedOnceWithTheLatestRange() async {
        let (queue, ran, _) = recordingQueue()
        let blocker = LotClaimQueue.Op.claim(cardId: UUID(), lotId: UUID(), rangeId: nil)
        let card = UUID(), lot = UUID(), picked = UUID()
        queue.enqueue(blocker)                   // in flight, so the next two wait
        queue.enqueue(.claim(cardId: card, lotId: lot, rangeId: nil))
        queue.enqueue(.claim(cardId: card, lotId: lot, rangeId: picked))
        await queue.drain()
        #expect(ran() == [blocker, .claim(cardId: card, lotId: lot, rangeId: picked)])
    }

    @Test func aReleaseThenAClaimOfOneSlabKeepTheirOrder() async {
        let (queue, ran, _) = recordingQueue()
        let lot = UUID(), card = UUID()
        let r = release("1", lot: lot)
        queue.enqueue(.release(r))
        queue.enqueue(.claim(cardId: card, lotId: lot, rangeId: nil))
        await queue.drain()
        #expect(ran() == [.release(r), .claim(cardId: card, lotId: lot, rangeId: nil)])
    }

    @Test func submitWaitsForItsOwnOp() async {
        let (queue, ran, _) = recordingQueue()
        let op = LotClaimQueue.Op.claim(cardId: UUID(), lotId: UUID(), rangeId: nil)
        await queue.submit(op)
        #expect(ran() == [op])
    }

    // MARK: Lot creation

    @Test func theBannerTypedAtCreationIsSent() throws {
        let insert = LotStore.LotInsert(id: UUID(), teamId: UUID(), name: "Weekend",
                                        deadline: nil, banner: "PSA only")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(insert)) as? [String: Any]
        #expect(json?["banner"] as? String == "PSA only")
    }

    // MARK: A claim for a card that moved on

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Card.self, Folder.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    /// Filed into a lot, then moved out before its queued claim ran: the claim must
    /// not send anything or mark the card — the card is no longer in that lot.
    @Test func aClaimForACardThatLeftTheLotDoesNothing() async throws {
        let ctx = try context()
        let card = Card(scan: CertScan(grader: .psa, certNumber: "66581638", raw: "66581638"))
        ctx.insert(card)
        card.folder = Folder(name: "consignment")            // a plain group now
        await LotClaims.claim(card, lotId: UUID(), in: ctx)
        #expect(card.lotClaimState == nil, "no 'checking', no request")
        #expect(card.lotClaimLotId == nil)
    }

    /// A card deleted (the undo window committed) while its claim waited must never
    /// be written to again.
    @Test func aDeletedCardIsNotAlive() throws {
        let ctx = try context()
        let card = Card(scan: CertScan(grader: .psa, certNumber: "1", raw: "1"))
        ctx.insert(card)
        try ctx.save()
        #expect(LotClaims.isAlive(card))
        ctx.delete(card)
        try ctx.save()
        #expect(!LotClaims.isAlive(card))
    }
}
