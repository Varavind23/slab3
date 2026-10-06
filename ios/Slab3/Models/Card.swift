import Foundation
import SwiftData

/// Where a card's detail lookup stands. Scanning always succeeds locally; the
/// name/set/grade fill in when the cert lookup resolves (or the user confirms).
/// Where a piece of a card's identity — or its picture — came from, ranked.
///
/// A card is described by three sources that are ALL already queried on a scan,
/// and they disagree about what they can offer. PSA is the grader whose label is
/// physically on the slab, so it wins; but PSA's cert page carries no photo of
/// the card unless the cert has SecureScan imagery, which most don't. Card Ladder
/// resolves by cert to a curated record with a canonical render, and it is the
/// only one of the three that covers CGC. Courtyard is last because its text is
/// marketplace listing copy and its match may be circumstantial.
///
/// This has to be STORED rather than implied by call order: the three writers are
/// independent async tasks, so without a rank the last one to finish wins,
/// nondeterministically, and a refresh could replace a good name with a worse one.
enum IdentitySource: String, Codable, Comparable {
    case none
    case camera // the scan's own frame — images only, and always the floor
    case courtyard
    case cardLadder
    case psa

    var rank: Int {
        switch self {
        case .none: 0
        case .camera: 1
        case .courtyard: 2
        case .cardLadder: 3
        case .psa: 4
        }
    }

    static func < (a: IdentitySource, b: IdentitySource) -> Bool { a.rank < b.rank }

    /// Shown under the card's picture. A reseller needs to know whether they are
    /// looking at their own photo before they trust it in a listing.
    var imageCaption: String {
        switch self {
        case .none: "No image"
        case .camera: "Camera capture"
        case .courtyard: "Courtyard vault render"
        case .cardLadder: "Card Ladder"
        case .psa: "PSA SecureScan"
        }
    }
}

enum LookupStatus: String, Codable {
    case pending // scanned, not yet looked up
    case resolved // card data present
    case needsConfirm // no source can answer (e.g. CGC) — user confirms from slab
    case notFound // valid format, no data at the grader
    /// The grader COULDN'T BE REACHED — a different fact from "no such cert",
    /// and the app used to collapse the two by silently doing nothing, leaving
    /// the row spinning on `pending` forever with no explanation. Prices already
    /// draw this distinction (`notListed` vs `unreachable`); identity now does
    /// too, because "PSA is blocking us" is something the user must be told
    /// rather than left to infer from a card that never fills in.
    case unavailable
}

/// Per-source price state. Split out from "the price is nil" because those are
/// three different facts and the app used to collapse them into one: a source
/// that has no comp for this card, a source that failed transiently (network,
/// rate limit, expired token), and a source we have never asked. Only the first
/// justifies clearing a price the user already saw.
enum PriceStatus: String, Codable {
    case unknown // never fetched
    case ok // fetched, price present and current
    case notListed // the source answered: it has no value for this card
    case unavailable // transient failure — any price shown is the last known one
    case notConnected // Card Ladder only: user hasn't connected their own account
}

/// One real completed sale of this card at this grade — a comp.
///
/// Stored rather than fetched on every view because the detail screen must still
/// show the last known comps offline, and because the fetch that produces them
/// costs Card Ladder budget (see PriceService.loadSales).
///
/// Never synthesized. A source with no comps yields an empty list, which is a
/// different fact from never having asked — the same distinction prices draw
/// between `.notListed` and `.unknown`.
struct RecentSale: Codable, Equatable, Identifiable {
    var priceCents: Int
    var soldAt: Date
    var platform: String?     // "eBay"
    var listingType: String?  // "Auction" | "BestOffer" | "FixedPrice"
    var title: String?
    var url: String?

    var id: String { "\(soldAt.timeIntervalSince1970)-\(priceCents)-\(url ?? "")" }

    /// "eBay · Best offer". Card Ladder sends listing types camel-cased.
    var provenance: String {
        let kind: String? = switch listingType {
        case "BestOffer": "Best offer"
        case "FixedPrice": "Fixed price"
        case let other: other
        }
        return [platform, kind].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A scanned graded card. Mirrors the `cards` table (supabase/migrations):
/// grader, cert_number, card_key, name, set, year, grade, scanned_at,
/// manual_price_cents, notes. `serverId` links to the row once synced.
@Model
final class Card {
    @Attribute(.unique) var localId: UUID
    var serverId: UUID?

    var graderRaw: String
    var certNumber: String
    var cardKey: String

    /// The SHORT name — PSA's Subject, Card Ladder's player. Feeds
    /// `refreshCardKey()`, so it is load-bearing beyond display: card_key is
    /// byte-identical across SQL/Swift/TS and drives price matching and the
    /// sale limit. The long assembled title must never be written here.
    var name: String?
    var set: String?
    var year: Int?
    var grade: String?
    /// The assembled title a grader renders: "2000 Pokemon Rocket #12 Dark
    /// Slowbro-Holo". Display and CSV only — deliberately NOT `name`.
    var title: String?
    /// The number printed on the card itself (PSA's "Card Number" label), not
    /// the cert number.
    var cardNumber: String?
    var identitySourceRaw: String = IdentitySource.none.rawValue

    var scannedAt: Date
    var lookupStatusRaw: String
    /// D10's "Manual price" override. Shown and editable in every build to 0.8 but
    /// read by nothing; kept so whatever testers typed there is never mistaken
    /// for a cost (see `paidCents`).
    var manualPriceCents: Int?
    /// What the user paid for this slab (opt-in, `AppState.tracksPaid`). Its own
    /// field, not `manualPriceCents`, so old "Manual price" entries never turn
    /// into a cost basis when someone switches the feature on (review 2026-10-02).
    var paidCents: Int?
    var notes: String?

    // Market prices (cents). These hold the LAST KNOWN good value: a failed
    // refresh must never blank a number the user already saw (that was the
    // "prices go blank on refresh" bug). The paired status/asOf say how much to
    // trust it, and only an authoritative "not listed" clears the value.
    var courtyardPriceCents: Int?
    var cardLadderPriceCents: Int?
    var courtyardStatusRaw: String = PriceStatus.unknown.rawValue
    var cardLadderStatusRaw: String = PriceStatus.unknown.rawValue
    /// When the stored price was actually fetched from the source (not when we
    /// last tried). Drives the "as of" marker on a stale column.
    var courtyardAsOf: Date?
    var cardLadderAsOf: Date?

    // ── The evidence behind the Card Ladder number (added 2026-08-29) ─────────
    // `cardLadderPriceCents` above is now Card Ladder VALUE — the figure their own
    // app labels "Value" — rather than a 30-day average. The average was silently
    // empty for plenty of well-known cards, which showed up as no price at all.
    //
    // These are additive and OPTIONAL on purpose: this project has no
    // VersionedSchema/SchemaMigrationPlan (Slab3App uses a bare
    // `.modelContainer(for:)`), so additive-optional is what lets SwiftData
    // lightweight-migrate the users already running build 1.

    /// Card Ladder's "Last Sold" — the single most recent real sale it has.
    var cardLadderLastSaleCents: Int?
    var cardLadderLastSaleAt: Date?

    /// Real recent sales per source, JSON-encoded `[RecentSale]`. `nil` means
    /// never fetched; an encoded EMPTY array means fetched and the source has
    /// none. Read through `cardLadderSales` / `courtyardSales`.
    ///
    /// WRITE THROUGH THOSE ACCESSORS, never to these blobs directly: the setters
    /// bump `compsRevision`, and `MaxBuyCache` trusts that stamp to decide whether
    /// a row's max buy is still valid. A direct write would leave a stale figure on
    /// screen until something unrelated changed.
    var cardLadderSalesData: Data?
    var courtyardSalesData: Data?
    var salesLoading: Bool = false

    /// Bumped whenever comps are written for either source. Exists so the max-buy
    /// memo can be invalidated with one `Int` compare instead of decoding both
    /// comps blobs — they decode on EVERY property read, and the Cards list would
    /// otherwise run thousands of `JSONDecoder`s a frame while sorting.
    ///
    /// Additive-optional per the SwiftData rule above; `nil` reads as revision 0.
    var compsRevision: Int?

    /// Each source's OWN confidence in its price, 0–5, written at fetch time
    /// (PriceService). 0 means the source stated none — never guessed upward.
    /// Courtyard's is bucketed to three segments for display.
    var courtyardConfidence: Int = 0
    var cardLadderConfidence: Int = 0

    /// Courtyard's census for this slab's OWN grade — how many of this card exist
    /// at this grade. It arrives on every scanner reply (per comp group, and once
    /// at card level) and was decoded but discarded until MaxBuyPrice needed it.
    ///
    /// Additive-optional per the SwiftData rule above. `nil` means Courtyard has
    /// not answered for this cert — never "few": a missing population contributes
    /// nothing to the calculation rather than being read as a small one.
    var courtyardPopulation: Int?

    /// The card's picture (46 × 64 on a row) — how a sourcer recognises what they
    /// scanned. The scan's own frame fills this immediately, so a row is never
    /// picture-less; an official render replaces it only if one actually exists.
    /// The row falls back to a placeholder rather than dropping the thumbnail.
    @Attribute(.externalStorage) var thumbnailData: Data?
    /// The official image's URL, kept so the detail screen can load a larger
    /// render than the ~1024px copy cached above.
    var imageUrl: String?
    var imageSourceRaw: String = IdentitySource.none.rawValue

    var pricesLoading: Bool = false

    // A card belongs to at most one group; nil shows under the "Ungrouped" filter.
    var folder: Folder?

    /// Where this card stands with a TEAM LOT (teams phase 4) — `LotClaimState`.
    /// nil for every card that was never filed into a lot. Kept on the card, not
    /// just derived from `folder`, because a BLOCKED card is un-filed back to plain
    /// inventory and still has to say why, and a claim must be releasable after the
    /// card has left the group. All three additive-optional (the SwiftData rule).
    var lotClaimStateRaw: String?
    /// The server lot the claim (or the attempt) was made against.
    var lotClaimLotId: UUID?
    /// The server's full answer (`LotVerdict`, JSON): the bucket, copy count, the
    /// three existing buys on a limit block, the candidates to pick from.
    var lotVerdictData: Data?
    /// Who sourced this slab — a team member or a virtual member (V4, 2026-10-04).
    /// PHONE-ONLY, for cards outside a lot: a lot slab's credit lives on its server
    /// claim (`TeamClaim.creditedPersonId`), which wins wherever both exist. The name
    /// is kept beside the id so Export and the row still read after the person is
    /// renamed elsewhere, removed, or the user leaves the team. Optional (SwiftData rule).
    var creditedPersonId: UUID?
    var creditedName: String?

    var grader: Grader { Grader(rawValue: graderRaw) ?? .psa }
    var lookupStatus: LookupStatus {
        get { LookupStatus(rawValue: lookupStatusRaw) ?? .pending }
        set { lookupStatusRaw = newValue.rawValue }
    }
    var courtyardStatus: PriceStatus {
        get { PriceStatus(rawValue: courtyardStatusRaw) ?? .unknown }
        set { courtyardStatusRaw = newValue.rawValue }
    }
    var cardLadderStatus: PriceStatus {
        get { PriceStatus(rawValue: cardLadderStatusRaw) ?? .unknown }
        set { cardLadderStatusRaw = newValue.rawValue }
    }
    // ── Comps ────────────────────────────────────────────────────────────────
    /// Decoded comps per source, newest first. `nil` = never fetched, `[]` =
    /// fetched and the source genuinely has none. The detail screen says
    /// something different for each, so the distinction must survive to the UI.
    var cardLadderSales: [RecentSale]? {
        get { Self.decodeSales(cardLadderSalesData) }
        set {
            cardLadderSalesData = Self.encodeSales(newValue)
            compsRevision = (compsRevision ?? 0) &+ 1
        }
    }
    var courtyardSales: [RecentSale]? {
        get { Self.decodeSales(courtyardSalesData) }
        set {
            courtyardSalesData = Self.encodeSales(newValue)
            compsRevision = (compsRevision ?? 0) &+ 1
        }
    }

    func sales(for source: PriceSource) -> [RecentSale]? {
        source == .cl ? cardLadderSales : courtyardSales
    }

    /// Corrupt stored JSON reads as "never fetched" rather than crashing — the
    /// screen then simply offers to load them again.
    private static func decodeSales(_ data: Data?) -> [RecentSale]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([RecentSale].self, from: data)
    }
    private static func encodeSales(_ sales: [RecentSale]?) -> Data? {
        guard let sales else { return nil }
        return try? JSONEncoder().encode(sales)
    }

    /// The row reads both of these with one index (see PriceSet / ConfidenceSet).
    var prices: PriceSet {
        PriceSet(cl: cardLadderPriceCents, cy: courtyardPriceCents)
    }
    var confidences: ConfidenceSet {
        ConfidenceSet(cl: cardLadderConfidence, cy: courtyardConfidence)
    }
    /// Most recent successful fetch across the two sources.
    var lastPricedAt: Date? {
        [courtyardAsOf, cardLadderAsOf].compactMap { $0 }.max()
    }
    /// A card counts as matched when at least one source has a price for it.
    var isMatched: Bool { prices.best(preferring: .cl) != nil }

    /// A price we hold but could not re-confirm on the last attempt. Still shown —
    /// a stale number beats an em dash the user knows is wrong — but the card
    /// detail screen says so, and `lastPricedAt` carries the real age.
    var courtyardIsStale: Bool { courtyardStatus == .unavailable && courtyardPriceCents != nil }
    var cardLadderIsStale: Bool { cardLadderStatus == .unavailable && cardLadderPriceCents != nil }

    /// Display title: real card data when resolved, else the cert reference.
    /// Deliberately prefers the SHORT name: "Dark Slowbro-Holo" is what
    /// distinguishes cards in a dense row, where the full assembled title
    /// truncates to nothing useful. The title is the fallback, not the default.
    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        if let title, !title.isEmpty { return title }
        return "\(grader.rawValue.uppercased()) #\(certNumber)"
    }
    var displaySubtitle: String {
        [set, grade.map { "Grade \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// The card row's second-line metadata: `2000 Pokemon Rocket · #12`.
    /// The card number is what separates two cards from the same set at a
    /// glance, so it belongs here rather than only on the detail screen.
    var metaLine: String {
        let head = [year.map(String.init), set].compactMap { $0 }.joined(separator: " ")
        let tail = cardNumber.map { "#\($0)" }
        let parts = [head.isEmpty ? nil : head, tail].compactMap { $0 }
        return parts.isEmpty ? "#\(certNumber)" : parts.joined(separator: " · ")
    }

    init(scan: CertScan) {
        self.localId = UUID()
        self.graderRaw = scan.grader.rawValue
        self.certNumber = scan.certNumber
        // card_key is provisional until lookup fills set/grade; recomputed then.
        self.cardKey = CardKey.make(grader: scan.grader, set: nil, cardId: scan.certNumber, grade: nil)
        self.scannedAt = Date()
        self.lookupStatusRaw = LookupStatus.pending.rawValue
    }

    var identitySource: IdentitySource {
        get { IdentitySource(rawValue: identitySourceRaw) ?? .none }
        set { identitySourceRaw = newValue.rawValue }
    }
    var imageSource: IdentitySource {
        get { IdentitySource(rawValue: imageSourceRaw) ?? .none }
        set { imageSourceRaw = newValue.rawValue }
    }

    /// Apply one source's answer about who this card is.
    ///
    /// A lower-ranked source can still FILL a field the better source left empty
    /// — PSA knows the subject but never the card's picture, Card Ladder knows a
    /// title for a CGC slab PSA won't answer for at all — but it can never
    /// overwrite what a better source already said. `identitySource` only ever
    /// rises, so re-running a refresh is idempotent rather than a coin flip.
    func setIdentity(
        name: String? = nil,
        title: String? = nil,
        set: String? = nil,
        year: Int? = nil,
        grade: String? = nil,
        cardNumber: String? = nil,
        from source: IdentitySource
    ) {
        let outranked = source < identitySource
        func take<T>(_ incoming: T?, _ current: T?) -> T? {
            guard let incoming else { return current }
            if current == nil { return incoming }   // fill a gap regardless of rank
            return outranked ? current : incoming
        }
        self.name = take(name?.isEmpty == false ? name : nil, self.name)
        self.title = take(title?.isEmpty == false ? title : nil, self.title)
        self.set = take(set?.isEmpty == false ? set : nil, self.set)
        self.year = take(year, self.year)
        // Grade goes through the same funnel as everything else. It used to be
        // written straight onto the card by PriceService, outside the rank rule,
        // so a circumstantial Courtyard hit could beat Card Ladder's cert-resolved
        // answer. Every source now states it as a bare number ("9", "10", "9.5")
        // so the badge, the comps header and card_key all agree on one spelling.
        self.grade = take(grade?.isEmpty == false ? grade : nil, self.grade)
        self.cardNumber = take(cardNumber?.isEmpty == false ? cardNumber : nil, self.cardNumber)
        if source > identitySource { identitySource = source }
        // name AND grade feed the key, so any change to either has to be reflected.
        refreshCardKey()
        // Identified is identified, whatever else failed on the way. This used to
        // promote only from `.pending`, which meant a PSA failure stamping
        // `.unavailable` permanently locked the card out of `.resolved` — so a
        // card Card Ladder had *successfully* named still displayed "PSA couldn't
        // be reached". The status describes the card, not the last source tried.
        if name != nil || title != nil { lookupStatus = .resolved }
    }

    /// Apply one source's picture. Same rule, with the camera capture as the
    /// floor: a real photo the user took beats no photo, and any official render
    /// beats the photo. Never downgrades, so a later refresh can't drop a good
    /// image back to the viewfinder grab.
    func setImage(_ data: Data, url: URL? = nil, from source: IdentitySource) {
        guard !data.isEmpty, source >= imageSource else { return }
        thumbnailData = data
        imageUrl = url?.absoluteString ?? (source == imageSource ? imageUrl : nil)
        imageSource = source
    }

    /// Recompute card_key once real card data is known (post-lookup/confirm).
    func refreshCardKey() {
        cardKey = CardKey.make(grader: grader, set: set, cardId: name ?? certNumber, grade: grade)
    }
}
