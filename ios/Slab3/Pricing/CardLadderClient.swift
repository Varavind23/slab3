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

    struct Price: Equatable {
        let priceCents: Int
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
        case ok(Int, Identity?) // average-sale cents + what CL knows about the card
        case notFound     // Card Ladder has no comps for this card
        case notConnected // user hasn't connected (or connection was cleared)
        case authExpired  // stored credentials no longer work — reconnect
        case unavailable  // rate limited / source error — transient
    }

    /// Fetch the Card Ladder average-sale price (cents) for a scanned card.
    /// `force` skips the server's 24h cache read — used by manual refresh so the
    /// user gets a genuinely current number rather than a replayed one.
    func price(cert: String, grader: Grader, cardKey: String, force: Bool = false) async -> PriceOutcome {
        struct Body: Encodable { let cert: String; let grader: String; let cardKey: String; let force: Bool }
        struct Reply: Decodable { let status: String; let priceCents: Int?; let identity: Identity? }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "cardladder-price",
                options: .init(body: Body(cert: cert, grader: grader.rawValue, cardKey: cardKey, force: force))
            )
            switch reply.status {
            case "ok": return reply.priceCents.map { .ok($0, reply.identity) } ?? .notFound
            case "not_found": return .notFound
            case "not_connected": return .notConnected
            case "auth_expired": return .authExpired
            default: return .unavailable // rate_limited / source_error
            }
        } catch {
            return .unavailable
        }
    }
}
