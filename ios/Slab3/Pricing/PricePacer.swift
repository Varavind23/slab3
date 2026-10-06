import Foundation
import SwiftData

/// Prices a pasted cert list ONE CARD AT A TIME, with a gap between cards.
///
/// WHY (owner decisions 2026-09-16 and 2026-10-01). Bulk refresh was removed
/// because one tap fired a stack-sized burst at Courtyard — which 403s an IP that
/// hammers it — and at Card Ladder, which allows ≤1 request a second and 200 a day
/// per user (docs/scan-and-pricing.md). A pasted list is the bulk path that came
/// back, so it carries the pacing that `PriceRefresher` held (deleted in 240f1ff):
/// 1100 ms between cards while Card Ladder is connected, 120 ms on a Courtyard-only
/// run. The scope is narrow by construction — only the cards just pasted, capped
/// at `CertBatch.cap`.
///
/// A singleton, so a list keeps pricing after the sheet closes or the tab changes.
/// Not persisted: an app killed mid-list leaves the rest unpriced, and those rows
/// refresh one at a time from the card's detail screen like any other.
///
/// Team lots: a batch card is filed with `pricesLoading` already set, so its claim
/// (`LotClaims.waitForPrices`) waits for THIS refresh instead of starting its own.
/// Both queues run in paste order, so claim N waits on the price that is next up.
@MainActor
final class PricePacer {
    static let shared = PricePacer()

    static let cardLadderGap = Duration.milliseconds(1100)   // ≤1 req/sec (Card Ladder)
    static let courtyardGap = Duration.milliseconds(120)     // Courtyard-only run

    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    private var context: ModelContext?

    /// What one card's turn does. Replaced in tests.
    var perform: (UUID, ModelContext?) async -> Void = PricePacer.run
    /// Replaced in tests, so a test neither waits nor depends on wall time.
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Read per card: a connection that drops mid-list speeds the rest up.
    var gap: () -> Duration = {
        UserDefaults.standard.bool(forKey: PriceService.connectedKey) ? cardLadderGap : courtyardGap
    }

    /// Cards waiting their turn (not counting one in flight). Tests read it.
    var pending: [UUID] { queue }
    var isIdle: Bool { queue.isEmpty && worker == nil }

    func enqueue(_ cardIds: [UUID], in context: ModelContext? = nil) {
        if let context { self.context = context }
        for id in cardIds where !queue.contains(id) { queue.append(id) }
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let id = self.queue.removeFirst()
                await self.perform(id, self.context)
                // After EVERY card, the last included: a second list pasted right
                // behind the first must not start inside the gap.
                await self.sleep(self.gap())
            }
            self?.worker = nil
        }
    }

    /// Wait for everything queued so far. Tests only.
    func drain() async {
        while let current = worker { await current.value }
    }

    /// The same work `ScanScreen.add` does for a scan, minus the burst.
    private static func run(_ id: UUID, _ context: ModelContext?) async {
        guard let context else { return }
        let find = FetchDescriptor<Card>(predicate: #Predicate { $0.localId == id })
        // Deleted while it waited: nothing to price.
        guard let card = try? context.fetch(find).first else { return }
        await PriceService.refresh(card, in: context)
        // PSA is walled and fails slowly (spike/README.md §4a) — it never holds
        // the next card's turn.
        Task { await PsaIdentityService.enrich(card) }
    }
}
