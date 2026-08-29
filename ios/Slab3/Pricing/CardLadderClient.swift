import Foundation

/// Talks to the Card Ladder Edge Functions (server-side, bring-your-own-account).
/// Unlike Courtyard (a direct public Algolia key), Card Ladder needs the user's OWN
/// paid account: they connect once, the server stores the credentials encrypted and
/// does the Firebase + Cloud Functions lookups. The app never holds CL credentials
/// beyond the moment of connecting, and never calls Card Ladder directly.
///
/// See supabase/functions/cardladder-{connect,price} and the shared client.
struct CardLadderClient {

    // MARK: Connect

    enum ConnectResult: Equatable {
        case connected
        case invalidCredentials
        case unreachable
    }

    /// Is THIS user connected, according to the server?
    ///
    /// The credentials live server-side keyed to the auth user, so the server is
    /// the authority — a local flag is only ever a cache of this. Returns nil if
    /// we could not ask, which must NOT be read as "disconnected": that
    /// conflation is what made a reinstall look like a lost subscription.
    /// Costs no Card Ladder request.
    func isConnected() async -> Bool? {
        struct Reply: Decodable { let ok: Bool; let connected: Bool? }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "cardladder-connect", options: .init(method: .get)
            )
            return reply.ok ? (reply.connected ?? false) : nil
        } catch {
            return nil
        }
    }

    /// Validate + store the user's Card Ladder credentials server-side.
    func connect(email: String, password: String) async -> ConnectResult {
        struct Body: Encodable { let email: String; let password: String }
        struct Reply: Decodable { let ok: Bool; let error: String? }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "cardladder-connect",
                options: .init(body: Body(email: email, password: password))
            )
            if reply.ok { return .connected }
            return reply.error == "invalid_credentials" ? .invalidCredentials : .unreachable
        } catch {
            return .unreachable
        }
    }

    // MARK: Price

    /// Everything the price call returns about the number itself. `valueCents`
    /// is Card Ladder VALUE (their app's "Value" column); `lastSaleCents` is
    /// their "Last Sold". Both ride the one call — see Identity below.
    struct Price: Equatable {
        let valueCents: Int
        let lastSaleCents: Int?
        let lastSaleAt: Date?
        let confidence: Int?
    }

    /// What Card Ladder knows about the card, alongside the price.
    ///
    /// This rides the price call — it is NEVER fetched separately. A second
    /// request per card would burn the per-user daily budget, which the user
    /// experiences as prices going blank. Card Ladder is the only one of the
    /// three sources that answers for CGC slabs at all.
    struct Identity: Equatable, Decodable {
        let label: String?      // "1986 Fleer #73 Kevin Mchale" — assembled title
        let player: String?     // "Kevin McHale" — the short name
        let set: String?
        let year: String?
        let cardNumber: String?
        let imageUrl: URL?      // Firebase download URL, public (`?alt=media`, no token)
    }

    /// Outcome of a price lookup, so the caller can update the local connection flag.
    enum PriceOutcome: Equatable {
        case ok(Price, Identity?) // Card Ladder Value + what CL knows about the card
        /// No price — but Card Ladder may still KNOW the card. A missing comp is
        /// not a missing card, and while PSA is walled this is often the only
        /// thing that can name a slab at all.
        case notFound(Identity?)
        case notConnected // user hasn't connected (or connection was cleared)
        case authExpired  // stored credentials no longer work — reconnect
        case unavailable  // rate limited / source error — transient
    }

    /// Fetch the Card Ladder VALUE (cents) for a scanned card, plus its last
    /// sale and Card Ladder's own confidence in it.
    ///
    /// The metric changed 2026-08-29: this used to be `oneMonthData.averagePrice`,
    /// a trailing 30-day mean that is simply empty for many well-known cards —
    /// so they showed no Card Ladder price at all. Value is the number Card
    /// Ladder itself displays. See supabase/functions/_shared/cardladder.ts.
    ///
    /// `force` skips the server's 24h cache read — used by manual refresh so the
    /// user gets a genuinely current number rather than a replayed one.
    func price(cert: String, grader: Grader, cardKey: String, force: Bool = false) async -> PriceOutcome {
        struct Body: Encodable { let cert: String; let grader: String; let cardKey: String; let force: Bool }
        struct Reply: Decodable {
            let status: String
            let priceCents: Int?
            let lastSaleCents: Int?
            /// Deliberately a String: the SDK decodes with a plain JSONDecoder,
            /// which cannot read an ISO date. See ISO8601.
            let lastSaleAt: String?
            let confidence: Int?
            let identity: Identity?
        }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "cardladder-price",
                options: .init(body: Body(cert: cert, grader: grader.rawValue, cardKey: cardKey, force: force))
            )
            switch reply.status {
            case "ok":
                guard let cents = reply.priceCents else { return .notFound(reply.identity) }
                return .ok(
                    Price(valueCents: cents, lastSaleCents: reply.lastSaleCents,
                          lastSaleAt: ISO8601.date(reply.lastSaleAt), confidence: reply.confidence),
                    reply.identity
                )
            case "not_found": return .notFound(reply.identity)
            case "not_connected": return .notConnected
            case "auth_expired": return .authExpired
            default: return .unavailable // rate_limited / source_error
            }
        } catch {
            return .unavailable
        }
    }

    // MARK: Sales

    /// Outcome of a comps lookup. `.ok([])` is a real answer — Card Ladder has no
    /// sales for this card — and is deliberately not collapsed into a failure.
    enum SalesOutcome: Equatable {
        case ok([RecentSale])
        case notConnected
        case authExpired
        case unavailable
    }

    /// Fetch this card's real recent sales at this grade.
    ///
    /// Called LAZILY, when the detail screen opens — never during a scan or a
    /// bulk refresh. It is a second Card Ladder request per card, and the daily
    /// budget is 200; spending it on comps nobody opened would read to the user
    /// as prices going blank. See supabase/functions/cardladder-sales.
    func sales(cert: String, grader: Grader, cardKey: String, force: Bool = false) async -> SalesOutcome {
        struct Body: Encodable { let cert: String; let grader: String; let cardKey: String; let force: Bool }
        struct Sale: Decodable {
            let priceCents: Int
            /// String for the same reason as lastSaleAt above.
            let soldAt: String
            let platform: String?
            let listingType: String?
            let title: String?
            let url: String?
        }
        struct Reply: Decodable { let status: String; let sales: [Sale]? }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "cardladder-sales",
                options: .init(body: Body(cert: cert, grader: grader.rawValue, cardKey: cardKey, force: force))
            )
            switch reply.status {
            case "ok":
                // A sale we cannot date is dropped rather than shown with a
                // wrong date — the list is evidence, and its order is the point.
                return .ok((reply.sales ?? []).compactMap { sale in
                    guard let soldAt = ISO8601.date(sale.soldAt) else { return nil }
                    return RecentSale(priceCents: sale.priceCents, soldAt: soldAt, platform: sale.platform,
                                      listingType: sale.listingType, title: sale.title, url: sale.url)
                })
            case "not_connected": return .notConnected
            case "auth_expired": return .authExpired
            default: return .unavailable // rate_limited / source_error
            }
        } catch {
            return .unavailable
        }
    }
}
