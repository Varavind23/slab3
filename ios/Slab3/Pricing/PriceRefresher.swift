import SwiftUI
import SwiftData

/// Drives a "refresh all prices in this list" action with visible progress.
///
/// Deliberately SEQUENTIAL with a small gap between cards: Card Ladder meters
/// programmatic use (a per-user daily budget server-side, and the plan's ≤1 req/sec
/// rule), so hammering it in parallel would burn the budget and risk the account.
/// A stack of 50 cards refreshes in well under a minute, which is fine for a manual
/// action the sourcer initiates.
@MainActor
@Observable
final class PriceRefresher {
    private(set) var isRefreshing = false
    private(set) var done = 0
    private(set) var total = 0
    /// Set when a refresh finishes with something worth telling the user.
    private(set) var notice: String?

    /// Human-readable progress for the toolbar ("3 / 12").
    var progressText: String { total > 0 ? "\(done) / \(total)" : "" }

    private static let gap = Duration.milliseconds(1100) // ≤1 req/sec (Card Ladder)
    private static let fastGap = Duration.milliseconds(120) // Courtyard-only run

    /// Re-fetch prices for every card in `cards`.
    ///
    /// `force` (skip the server's 24h Card Ladder cache) defaults to FALSE here on
    /// purpose. It used to be true, which meant every pull-to-refresh went to the
    /// live source and burned the per-user daily budget (200/day) — refresh a
    /// 60-card folder three times and the rest of the day returns `rate_limited`,
    /// which is exactly the "it worked earlier, now it's blank" report. CL averages
    /// move slowly and the cache TTL is 24h, so cache-first is the honest default;
    /// the single-card detail screen still offers a forced refresh.
    func refresh(_ cards: [Card], in context: ModelContext, force: Bool = false) async {
        guard !isRefreshing, !cards.isEmpty else { return }
        isRefreshing = true
        notice = nil
        done = 0
        total = cards.count
        defer { isRefreshing = false }

        let wasConnected = UserDefaults.standard.bool(forKey: PriceService.connectedKey)
        var cardLadderLive = wasConnected
        var unavailable = 0 // cards where a source couldn't be reached this run
        var noPrice = 0 // cards neither source lists

        for (i, card) in cards.enumerated() {
            if Task.isCancelled { break }
            let result = await PriceService.refresh(
                card, in: context, force: force, includeCardLadder: cardLadderLive
            )
            if result.courtyard == .unavailable || result.cardLadder == .unavailable { unavailable += 1 }
            if card.courtyardPriceCents == nil && card.cardLadderPriceCents == nil { noPrice += 1 }

            // Connection dropped mid-run: stop touching Card Ladder for the rest of
            // the folder rather than clearing every remaining CL price behind it.
            if cardLadderLive && !UserDefaults.standard.bool(forKey: PriceService.connectedKey) {
                cardLadderLive = false
            }

            done = i + 1
            // ≤1 req/sec is a Card Ladder constraint; Courtyard-only runs don't
            // need to crawl.
            if i < cards.count - 1 { try? await Task.sleep(for: cardLadderLive ? Self.gap : Self.fastGap) }
        }

        try? context.save()
        notice = buildNotice(wasConnected: wasConnected, unavailable: unavailable, noPrice: noPrice, total: cards.count)
    }

    /// One line, factual, no apology (Caliper voice: no apology). Most-actionable cause first.
    private func buildNotice(wasConnected: Bool, unavailable: Int, noPrice: Int, total: Int) -> String? {
        if wasConnected && !UserDefaults.standard.bool(forKey: PriceService.connectedKey) {
            return "Card Ladder disconnected — reconnect in Settings."
        }
        if unavailable > 0 {
            return "\(unavailable) of \(total) couldn't be checked — showing the last known price. Check connection and try again."
        }
        if noPrice == total {
            return "No price found for these cards. Add manually or skip."
        }
        // A partial "N aren't listed" is deliberately NOT surfaced: the rows
        // already show it, and an alert on every refresh is noise.
        return nil
    }

    func clearNotice() { notice = nil }
}
