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
    var manualPriceCents: Int?
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

    /// Match confidence 0–5 per source, derived at fetch time (PriceService).
    /// README.md open question 2 asks the client to define the real scale; until
    /// then these are derived from how the match was actually made, never guessed.
    var courtyardConfidence: Int = 0
    var cardLadderConfidence: Int = 0

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
        self.cardNumber = take(cardNumber?.isEmpty == false ? cardNumber : nil, self.cardNumber)
        if source > identitySource { identitySource = source }
        // name feeds the key, so any change to it has to be reflected.
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
