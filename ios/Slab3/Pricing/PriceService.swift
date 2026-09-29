import Foundation
import SwiftData

/// Fetches a card's market prices and writes them back to the store. Two sources,
/// fetched independently so one failing never blocks the other:
///   • Courtyard — the SCANNER endpoint (cert-keyed, via courtyard-price), which is
///     the price, the identity and the comps. Algolia is kept for the cert-keyed
///     render image only; it indexes the marketplace, so it blanked most scanned
///     cards and could match a different one (spike/README.md §2b).
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
    /// Algolia — retained for the cert-keyed render image only (see refreshCourtyard).
    private static let courtyard = CourtyardClient()
    /// Courtyard's own scanner API: price + identity + comps in one call.
    private static let scanner = CourtyardScannerClient()
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

    /// Clear refresh flags left set by a refresh the app never finished.
    ///
    /// `pricesLoading` is a STORED property, so an app killed mid-refresh (swiped
    /// away during a scan) saved it `true` — and nothing ever set it back. That card's
    /// "Refresh prices now" stayed disabled for good, and a team lot claim waiting on
    /// it sat out its full 30 seconds (found in a Simulator run, 2026-09-28; the flag
    /// has been stored since 2026-08-22). On a fresh launch nothing is refreshing, so
    /// every `true` is stale. Returns how many it cleared.
    @discardableResult
    static func clearStaleLoading(in context: ModelContext) -> Int {
        let stuck = FetchDescriptor<Card>(predicate: #Predicate { $0.pricesLoading })
        let cards = (try? context.fetch(stuck)) ?? []
        for card in cards { card.pricesLoading = false }
        if !cards.isEmpty { try? context.save() }
        return cards.count
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
        result.courtyard = await refreshCourtyard(card, force: force)
        if includeCardLadder {
            result.cardLadder = await refreshCardLadder(card, force: force)
        } else {
            result.cardLadder = card.cardLadderStatus
        }
        return result
    }

    // MARK: Courtyard

    @discardableResult
    private static func refreshCourtyard(_ card: Card, force: Bool = false) async -> PriceStatus {
        // Cert-keyed, so there is no matching to get wrong: the endpoint either
        // knows this cert or it does not. That retires the whole `identify()`
        // problem for this source — the Algolia path could only ever answer with
        // "a slab of the same card", and when it guessed it priced someone else's.
        switch await scanner.lookup(cert: card.certNumber, grader: card.grader, force: force) {
        case .unavailable:
            // Their GemRate upstream, or ours. Keeps the last value, marks stale.
            applyCourtyard(.unreachable, to: card)
            return .unavailable

        case .noPrice(let identity, let groups):
            // Either Courtyard's catalog has no such cert, or it knows the card and
            // has no model price — it says the latter with price 0 / confidence 0
            // and its own app renders "not applicable". Both are authoritative and
            // both show an em dash; neither is ever a $0.
            applyCourtyard(.notListed, to: card)
            card.courtyardConfidence = 0
            if let identity { applyScannerIdentity(identity, to: card) }
            applyScannerSales(groups, to: card)
            applyScannerPopulation(groups, identity: identity, to: card)
            if card.lookupStatus == .pending, card.name == nil, card.title == nil {
                card.lookupStatus = .needsConfirm
            }
            // A card Courtyard cannot price still has a slab photograph, and this is
            // the row that needs one most — no price and no marketplace listing.
            await fillCourtyardImage(card, scannerImageUrl: identity?.imageUrl)
            return .notListed

        case .ok(let price, let identity, let groups):
            applyCourtyard(.price(price.valueCents), to: card)
            // Courtyard's OWN 1-5 confidence — the figure its app buckets to
            // low/medium/high. The old match-quality tiers are gone with the
            // matching: a cert hit is this slab, so there is nothing to discount.
            card.courtyardConfidence = price.confidence ?? 5
            applyScannerIdentity(identity, to: card)
            applyScannerSales(groups, to: card)
            applyScannerPopulation(groups, identity: identity, to: card)
            await fillCourtyardImage(card, scannerImageUrl: identity.imageUrl)
            return .ok
        }
    }

    /// Courtyard's cert-exact identity. Ranked below Card Ladder in the funnel
    /// (both are cert-exact and should agree; CL is the paid, authoritative one),
    /// so this FILLS what CL has not answered and never overwrites it.
    private static func applyScannerIdentity(_ id: CourtyardScannerClient.Identity, to card: Card) {
        card.setIdentity(
            name: id.subject,          // the short name — feeds card_key
            title: id.title,           // the long assembled one — display only
            set: id.set,
            year: id.year.flatMap { Int($0) },
            // Already a bare number from the server. Before this source, Card
            // Ladder was the only supplier of a grade at all — so a user with no
            // CL account now gets one, and their card_key stops collapsing.
            grade: id.grade,
            cardNumber: id.cardNumber,
            from: .courtyard
        )
    }

    /// Comps for the slab's OWN grader and grade. Called AFTER the identity so the
    /// grade it selects on is populated. A slab whose grade has no group gets [] —
    /// a real answer ("Courtyard has no sales at this grade"), never another
    /// grade's sales, which is what the panel would otherwise imply are this
    /// card's.
    private static func applyScannerSales(_ groups: [CourtyardScannerClient.SaleGroup], to card: Card) {
        card.courtyardSales = CourtyardScannerClient.sales(
            from: groups, grader: card.grader, grade: card.grade)
    }

    /// Courtyard's census at this slab's grade. Like the comps above, this is
    /// called AFTER the identity so the grade it selects on is populated.
    ///
    /// Written only on the two AUTHORITATIVE branches — a `.unavailable` keeps the
    /// last known figure, the same rule prices follow, because a GemRate outage is
    /// not evidence that a card's population changed.
    private static func applyScannerPopulation(_ groups: [CourtyardScannerClient.SaleGroup],
                                               identity: CourtyardScannerClient.Identity?,
                                               to card: Card) {
        card.courtyardPopulation = CourtyardScannerClient.population(
            from: groups, identity: identity, grader: card.grader, grade: card.grade)
    }

    /// The slab photograph.
    ///
    /// `scannerImageUrl` is Courtyard's OWN photo of this exact slab, from
    /// `/scanner/card-grader-image` via the Edge Function. It is preferred over
    /// everything else because it is cert-verified at the source — an unknown cert
    /// returns no image rather than someone else's — so it clears the "official
    /// image only on an exact cert match" rule by construction, with no matching
    /// for us to get wrong.
    ///
    /// Algolia stays as the fallback only. Measured 2026-09-05: over four certs it
    /// had an exact-cert hit on ONE, missing even cert 96679812, which prices
    /// perfectly — the image gap was always far wider than the price gap. The
    /// scanner route answered 9 of 9. See spike/README.md §2e.
    private static func fillCourtyardImage(_ card: Card, scannerImageUrl: String? = nil) async {
        guard card.thumbnailData == nil || card.imageSource < .courtyard else { return }

        if let raw = scannerImageUrl, let url = URL(string: raw) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return }
            card.setImage(ImageDownscale.normalized(data), url: url, from: .courtyard)
            return
        }

        guard case .match(let match) = await courtyard.lookup(
            grader: card.grader, certNumber: card.certNumber, name: card.name,
            set: card.set, grade: card.grade, year: card.year, cardNumber: card.cardNumber)
        else { return }
        await applyCourtyardImage(match, to: card)
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
            // The ONLY authoritative grade in the pipeline: the barcode carries a
            // cert number and nothing else, and PSA's cert page is walled. Before
            // 2026-08-31 the server dropped this field, so every card's grade was
            // nil and card_key collapsed a PSA 9 onto a PSA 10.
            grade: identity.grade,
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

        // Order-independent since 2026-08-31: the server caches under Card
        // Ladder's own {profileId}:{gradeCode}, resolved from the cert, so nothing
        // Courtyard does to card_key can move the row this call reads. It used to
        // matter, and getting it wrong is what served a PSA 9 the PSA 10's price.
        let outcome = await cardLadder.price(cert: card.certNumber, grader: card.grader, force: force)
        switch outcome {
        case .ok(let price, let identity):
            applyCardLadder(.price(price.valueCents), to: card)
            // Card Ladder's "Last Sold", shown under the Value on the detail
            // screen. Follows the price rule: only an authoritative answer
            // replaces it, so a transient failure below leaves it alone.
            card.cardLadderLastSaleCents = price.lastSaleCents
            card.cardLadderLastSaleAt = price.lastSaleAt
            // Card Ladder's OWN 1-5 confidence in its estimate — the same kind of
            // figure Courtyard's meter shows, which is what lets the two meters sit
            // side by side. It used to be pinned at 5 because a cert-keyed hit is
            // always the right CARD, but that grades the match, which is never in
            // doubt, and threw away the only statement about the VALUE's
            // reliability. Absent means unknown: an empty meter, never a made-up 5.
            // The cert-keyed hit still makes identity and render safe to trust.
            card.cardLadderConfidence = price.confidence ?? 0
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
            cert: card.certNumber, grader: card.grader, force: force)
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
