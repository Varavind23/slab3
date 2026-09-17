import Foundation

/// Courtyard's SCANNER price — the number Courtyard's own app shows for a scanned
/// slab, via the `courtyard-price` Edge Function.
///
/// Why this exists alongside CourtyardClient (Algolia): Algolia indexes the
/// MARKETPLACE — the slabs Courtyard has vaulted — and cards age out of it, so it
/// blanked most scanned cards and, when it did match loosely, risked pricing a
/// different card. This endpoint is cert-keyed and backed by a pricing MODEL, so
/// it answers for cards Courtyard has never held and CANNOT return another card:
/// the cert is the key. Confirmed against Courtyard's app on device 2026-08-31 —
/// cert 96679812 reads $50.80 / medium confidence in both. See spike/README.md §2b.
///
/// It goes through our server rather than straight from the phone even though the
/// upstream needs no auth: one global `cy_scan_cache` row per cert serves every
/// user, so a 200-slab refresh is not 200 requests per device. Courtyard 403s an
/// IP that hammers it.
///
/// One call returns price, identity AND comps, which is why this client returns
/// all three together — they arrive together and are true together.
struct CourtyardScannerClient {

    /// Courtyard's cert-exact answer about the card itself.
    ///
    /// `grade` is the load-bearing field: it is a card_key segment, and until this
    /// source landed Card Ladder was the ONLY supplier of one (the slab barcode
    /// carries a cert and nothing else; PSA's cert page has been 403-walled since
    /// 2026-08-28). This gives a grade to users with no Card Ladder account.
    struct Identity: Equatable, Decodable {
        let grade: String?       // bare number: "9", "10", "9.5"
        let title: String?       // assembled; belongs in Card.title, never Card.name
        let subject: String?     // the short name — "Stephen Curry"
        let set: String?
        let year: String?
        let cardNumber: String?
        let category: String?
        let population: Int?
        let imageUrl: String?
    }

    /// One comp group. Read by GRADER + GRADE, never by title: a card's history
    /// spans graders, and every group repeats the SCANNED card's title — cert
    /// 96679812 returns two grade-10 groups, PSA (pop 23) and SGC (pop 3), both
    /// labelled "(PSA g10)".
    struct SaleGroup: Decodable {
        struct Sale: Decodable {
            let priceCents: Int
            /// String, not Date: the SDK decodes with a plain JSONDecoder. UTC
            /// midnight — render in LOCAL time or we disagree with Courtyard's own
            /// app by a day.
            let soldAt: String
        }
        let grader: String?
        let grade: String?
        let population: Int?
        let sales: [Sale]
    }

    struct Price {
        let valueCents: Int
        /// Courtyard's OWN 1-5 confidence — the figure its app buckets to
        /// low/medium/high beside the price.
        let confidence: Int?
    }

    enum Outcome {
        case ok(Price, Identity, [SaleGroup])
        /// Courtyard's catalog knows no such cert, OR knows the card and has no
        /// model price for it — it states the latter as price 0 / confidence 0 and
        /// its own app renders "not applicable". Either way there is no number, and
        /// the UI shows an em dash. The identity survives when there is one.
        case noPrice(Identity?, [SaleGroup])
        /// Transient: their GemRate upstream failing, or the network. MUST NOT
        /// clear a price the user already saw.
        case unavailable
    }

    /// `force` skips the server's 24h cache read, for manual refresh.
    func lookup(cert: String, grader: Grader, force: Bool = false) async -> Outcome {
        struct Body: Encodable { let cert: String; let grader: String; let force: Bool }
        struct Reply: Decodable {
            let status: String
            let priceCents: Int?
            let confidence: Int?
            let identity: Identity?
            let comps: [SaleGroup]?
        }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "courtyard-price",
                options: .init(body: Body(cert: cert, grader: grader.rawValue, force: force))
            )
            let comps = reply.comps ?? []
            switch reply.status {
            case "ok":
                // priceCents nil = Courtyard knows the card but has no model price.
                // Never coerce that to 0 — a $0 in the UI is a fabricated price.
                guard let cents = reply.priceCents, cents > 0 else {
                    return .noPrice(reply.identity, comps)
                }
                return .ok(Price(valueCents: cents, confidence: reply.confidence),
                           reply.identity ?? Identity(grade: nil, title: nil, subject: nil, set: nil,
                                                      year: nil, cardNumber: nil, category: nil,
                                                      population: nil, imageUrl: nil),
                           comps)
            case "not_found":
                return .noPrice(reply.identity, comps)
            default:
                return .unavailable // source_error / unauthorized / bad_request
            }
        } catch {
            return .unavailable
        }
    }

    /// The slab's OWN grade's sales, newest first — what the detail screen shows.
    ///
    /// Returns [] rather than another grade's sales when this grade has none: a
    /// g9 slab whose only comps are g10 (cert 154334127) gets an empty panel, not
    /// someone else's numbers. Mirrors salesForGrade in the worker adapter.
    static func sales(from groups: [SaleGroup], grader: Grader, grade: String?) -> [RecentSale] {
        guard let grade else { return [] }
        let want = grader.rawValue.uppercased()
        guard let group = groups.first(where: {
            ($0.grader ?? "").uppercased() == want && $0.grade == grade
        }) else { return [] }
        return group.sales.compactMap { s in
            guard let date = ISO8601.date(s.soldAt) else { return nil }
            return RecentSale(priceCents: s.priceCents, soldAt: date)
        }
    }

    /// The census for the slab's OWN grade. Mirrors `populationForGrade` in the
    /// worker adapter: the matching group's figure, falling back to the card-level
    /// one when this grade has no group.
    ///
    /// Grade first, because that is the number that decides whether a market is
    /// thin — cert 4260611176 has 380 graded copies but only 11 at PSA 9, and it
    /// is the 11 that moves a price. Returns nil when nothing is known, which is
    /// NOT the same as 0: Courtyard reports a real 0 for CGC pristine-10 groups,
    /// and that means the thinnest possible market rather than an absent answer.
    static func population(from groups: [SaleGroup], identity: Identity?,
                           grader: Grader, grade: String?) -> Int? {
        let want = grader.rawValue.uppercased()
        if let grade,
           let group = groups.first(where: {
               ($0.grader ?? "").uppercased() == want && $0.grade == grade
           }),
           let pop = group.population {
            return pop
        }
        return identity?.population
    }
}
