import Foundation
import SwiftData

/// Fetches a card's market prices and writes them back to the store. Two sources,
/// fetched independently so one failing never blocks the other:
///   • Courtyard — live, direct Algolia (public key), also auto-fills identity.
///   • Card Ladder — server-side, bring-your-own-account: only fetched when the user
///     has connected their own CL account (see CardLadderConnectView).
///
/// The rule this file exists to enforce: **a refresh never destroys a price the
/// user already saw.** Previously every non-success — a dropped connection, a
/// rate-limited day, an Algolia blip — wrote `nil` over a good number, which is
/// why prices "came up blank on refresh even when they were listed before". Now
/// only an authoritative "this source has no value for this card" clears a price;
/// everything else keeps the last known value and marks the column stale
/// (Card.PriceStatus). We still never fabricate a price (CLAUDE.md).
@MainActor
enum PriceService {
    private static let courtyard = CourtyardClient()
    private static let cardLadder = CardLadderClient()

    /// Set true after a successful connect; cleared if the server reports the
    /// connection is gone. Drives whether we attempt Card Ladder at all + the UI CTA.
    static let connectedKey = "cardladder_connected"

    /// What a refresh actually managed to do, so a bulk run can tell the user
    /// something specific instead of leaving them to guess at empty columns.
    struct Result {
        var courtyard: PriceStatus = .unknown
        var cardLadder: PriceStatus = .unknown
        /// True when at least one source produced a number this round.
        var gotAnyPrice: Bool { courtyard == .ok || cardLadder == .ok }
    }

    @discardableResult
    /// `includeCardLadder: false` leaves the Card Ladder column completely
    /// untouched. A bulk run sets it once the connection has dropped, so one
    /// expired token doesn't march through the folder blanking every CL price.
    static func refresh(
        _ card: Card,
        in context: ModelContext,
        force: Bool = false,
        includeCardLadder: Bool = true
    ) async -> Result {
        card.pricesLoading = true
        defer { card.pricesLoading = false }
        var result = Result()
        result.courtyard = await refreshCourtyard(card)
        if includeCardLadder {
            result.cardLadder = await refreshCardLadder(card, force: force)
        } else {
            result.cardLadder = card.cardLadderStatus
        }
        return result
    }

    // MARK: Courtyard

    @discardableResult
    private static func refreshCourtyard(_ card: Card) async -> PriceStatus {
        switch await courtyard.lookup(
            grader: card.grader,
            certNumber: card.certNumber,
            name: card.name,
            set: card.set,
            grade: card.grade,
            year: card.year,
            cardNumber: card.cardNumber
        ) {
        case .failed:
            applyCourtyard(.unreachable, to: card)
            return .unavailable

        case .notListed:
            applyCourtyard(.notListed, to: card)
            card.courtyardConfidence = 0
            if card.lookupStatus == .pending { card.lookupStatus = .needsConfirm }
            return .notListed

        case .match(let match):
            applyCourtyard(.price(match.priceCents), to: card)
            // On an exact cert match, prefer COURTYARD's own 1-5 confidence in
            // its value — that is the number its app shows next to the price, and
            // it says something we cannot know ourselves. Otherwise fall back to
            // how the match was made: a grade+name hit is circumstantial, a fuzzy
            // hit is barely evidence, and quoting Courtyard's confidence in a
            // different card's value would overstate what we know.
            // Only two tiers survive matching now (see CourtyardClient.bestMatch):
            // this slab, or a different slab of the same card. A looser hit is
            // no longer priced at all.
            let matchConfidence = switch match.confidence {
            case .exact: 5
            case .probable: 3
            case .fuzzy: 1
            }
            card.courtyardConfidence = match.sourceConfidence ?? matchConfidence

            // Auto-fill identity from an exact/probable Courtyard match. The
            // funnel decides what survives: Courtyard can fill what PSA left
            // empty but never overwrite what PSA answered.
            if match.confidence != .fuzzy {
                if card.grade == nil { card.grade = match.grade }
                card.setIdentity(
                    name: match.name, title: match.title, set: match.set,
                    year: match.year, cardNumber: match.cardNumber, from: .courtyard
                )
                await applyCourtyardImage(match, to: card)
            } else if card.lookupStatus == .pending {
                card.lookupStatus = .needsConfirm
            }
            return .ok
        }
    }

    /// Courtyard's render, but ONLY on an exact cert hit.
    ///
    /// The image is keyed by cert, so an exact match really is this slab. A
    /// `.probable` or `.fuzzy` Algolia hit is a DIFFERENT card, and putting its
    /// picture on this row is the image analogue of fabricating a price.
    private static func applyCourtyardImage(_ match: CourtyardClient.Match, to card: Card) async {
        guard match.confidence == .exact else { return }
        // The inline preview lands first so the row stops being blank now; the
        // full render replaces it at the same rank when it arrives.
        if let lqip = match.lqipBase64, let data = Data(base64Encoded: lqip) {
            card.setImage(data, url: match.imageUrl, from: .courtyard)
        }
        guard let url = match.imageUrl,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return }
        card.setImage(ImageDownscale.normalized(data), url: url, from: .courtyard)
    }

    /// Card Ladder's identity + card render. Cert-resolved, so always exact —
    /// and the only source that gives a CGC slab a name and a picture at all.
    private static func applyCardLadderIdentity(_ identity: CardLadderClient.Identity, to card: Card) async {
        card.setIdentity(
            name: identity.player,
            title: identity.label,
            set: identity.set,
            year: identity.year.flatMap { Int($0) },
            cardNumber: identity.cardNumber,
            from: .cardLadder
        )
        guard let url = identity.imageUrl,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return }
        card.setImage(ImageDownscale.normalized(data), url: url, from: .cardLadder)
    }

    // MARK: Card Ladder

    @discardableResult
    private static func refreshCardLadder(_ card: Card, force: Bool = false) async -> PriceStatus {
        // Only fetch for users who connected their own Card Ladder account. This
        // one DOES clear the price: showing CL data to a user whose subscription
        // no longer covers it is the ToS line the server-side gating draws.
        guard UserDefaults.standard.bool(forKey: connectedKey) else {
            applyCardLadder(.notConnected, to: card)
            card.cardLadderConfidence = 0
            return .notConnected
        }

        // Courtyard auto-fill can rewrite card_key (name replaces cert as the
        // card id), so we deliberately price Card Ladder *after* Courtyard — the
        // key we send is then the stable one the cache will be keyed under.
        let outcome = await cardLadder.price(cert: card.certNumber, grader: card.grader, cardKey: card.cardKey, force: force)
        switch outcome {
        case .ok(let price, let identity):
            applyCardLadder(.price(price.valueCents), to: card)
            // Card Ladder's "Last Sold", shown under the Value on the detail
            // screen. Follows the price rule: only an authoritative answer
            // replaces it, so a transient failure below leaves it alone.
            card.cardLadderLastSaleCents = price.lastSaleCents
            card.cardLadderLastSaleAt = price.lastSaleAt
            // Card Ladder resolves by cert number server-side, so a hit is exact
            // by construction — there is no fuzzy path to score lower. That also
            // makes its identity and its card render safe to trust outright.
            card.cardLadderConfidence = 5
            if let identity { await applyCardLadderIdentity(identity, to: card) }
            return .ok

        case .notFound(let identity):
            applyCardLadder(.notListed, to: card)
            card.cardLadderConfidence = 0
            // Authoritative "no value" clears the supporting figures too.
            card.cardLadderLastSaleCents = nil
            card.cardLadderLastSaleAt = nil
            // No comps, but Card Ladder may still know exactly what this is.
            if let identity { await applyCardLadderIdentity(identity, to: card) }
            return .notListed

        case .unavailable:
            // Rate limited / source error / offline — keep the last known number.
            applyCardLadder(.unreachable, to: card)
            return .unavailable

        case .notConnected, .authExpired:
            // The server no longer has a working connection — reflect that so the UI
            // shows the reconnect CTA again.
            applyCardLadder(.notConnected, to: card)
            card.cardLadderConfidence = 0
            UserDefaults.standard.set(false, forKey: connectedKey)
            return .notConnected
        }
    }

    /// Reconcile the local connection flag with the server, which is the
    /// authority. Called once after auth.
    ///
    /// Without this the flag is write-only local state: reinstall the app (or run
    /// a second build with its own container) and Card Ladder reads as
    /// disconnected forever, because `refreshCardLadder` short-circuits on the
    /// flag before it ever asks the server. An unreachable server leaves the flag
    /// ALONE — "couldn't ask" is not "not connected", the same distinction
    /// prices draw between unavailable and notListed.
    static func syncConnectionState() async {
        guard let connected = await cardLadder.isConnected() else { return }
        UserDefaults.standard.set(connected, forKey: connectedKey)
    }

    // MARK: Sales (comps)

    /// Load this card's real recent sales. Called from the card detail screen on
    /// appear — deliberately NOT part of `refresh`.
    ///
    /// Comps cost a second Card Ladder request per card against a 200/day budget.
    /// Folding them into a scan or a bulk refresh would halve how many slabs a
    /// user can run through a stack, and the user would experience that as prices
    /// going blank — the exact failure the cache-first rule exists to prevent.
    ///
    /// Cache-first is handled server-side (24h), so re-opening a card is free.
    static func loadSales(_ card: Card, in context: ModelContext, force: Bool = false) async {
        guard !card.salesLoading else { return }
        // Already have them and not explicitly refreshing: nothing to do. An
        // EMPTY stored list counts as having them — "Card Ladder has no comps"
        // is an answer, not a reason to ask again every time the screen opens.
        if card.cardLadderSales != nil && card.courtyardSales != nil && !force { return }

        card.salesLoading = true
        defer { card.salesLoading = false }

        // Courtyard first: unauthenticated, costs no budget, and independent of
        // whether the user has connected Card Ladder at all.
        if card.courtyardSales == nil || force {
            card.courtyardSales = await courtyard.recentSales(
                name: card.name, set: card.set, grader: card.grader, grade: card.grade,
                certNumber: card.certNumber, year: card.year, cardNumber: card.cardNumber)
        }

        guard UserDefaults.standard.bool(forKey: connectedKey) else {
            try? context.save()
            return
        }

        let outcome = await cardLadder.sales(
            cert: card.certNumber, grader: card.grader, cardKey: card.cardKey, force: force)
        switch outcome {
        case .ok(let sales):
            card.cardLadderSales = sales
        case .notConnected, .authExpired:
            UserDefaults.standard.set(false, forKey: connectedKey)
        case .unavailable:
            // Keep whatever we already showed. Same rule as prices: a failed
            // fetch never erases evidence the user has already seen.
            break
        }
        try? context.save()
    }

    // MARK: Write-back (rule lives in PriceWriteback, tested there)

    private static func applyCourtyard(_ answer: PriceWriteback.Answer, to card: Card) {
        let next = PriceWriteback.apply(answer, to: .init(
            cents: card.courtyardPriceCents, asOf: card.courtyardAsOf, status: card.courtyardStatus))
        card.courtyardPriceCents = next.cents
        card.courtyardAsOf = next.asOf
        card.courtyardStatus = next.status
    }

    private static func applyCardLadder(_ answer: PriceWriteback.Answer, to card: Card) {
        let next = PriceWriteback.apply(answer, to: .init(
            cents: card.cardLadderPriceCents, asOf: card.cardLadderAsOf, status: card.cardLadderStatus))
        card.cardLadderPriceCents = next.cents
        card.cardLadderAsOf = next.asOf
        card.cardLadderStatus = next.status
    }
}
