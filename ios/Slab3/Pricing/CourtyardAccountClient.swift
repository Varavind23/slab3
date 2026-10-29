import Foundation

/// Connects the user's OWN Courtyard account, through the `courtyard-connect` Edge
/// Function.
///
/// Why this exists: since 2026-10-29 Courtyard's scanner answers only to a
/// logged-in Courtyard account (spike/README.md §2g), so Courtyard prices became
/// bring-your-own-account like Card Ladder (owner decisions C1/C2). Courtyard has
/// no password — it logs in by emailed code — so connecting is two steps: `start`
/// has Courtyard email the user a code, `verify` sends it back. The server keeps
/// the session sealed; the app holds nothing but a "connected" flag.
struct CourtyardAccountClient {

    enum StartResult: Equatable {
        case sent
        case invalidEmail
        case rateLimited
        case unreachable
    }

    enum VerifyResult: Equatable {
        case connected(emailHint: String?)
        case invalidCode
        /// Courtyard has no account for that email. We never create one.
        case noAccount
        /// Logged in, but Courtyard's scanner refused the session.
        case rejected
        case rateLimited
        case unreachable
    }

    /// Is THIS user connected, according to the server? nil = could not ask,
    /// which must never be read as "disconnected" (the CardLadderClient rule).
    func isConnected() async -> Bool? {
        struct Reply: Decodable { let ok: Bool; let connected: Bool? }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "courtyard-connect", options: .init(method: .get)
            )
            return reply.ok ? (reply.connected ?? false) : nil
        } catch {
            return nil
        }
    }

    func start(email: String) async -> StartResult {
        struct Body: Encodable { let step = "start"; let email: String }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "courtyard-connect", options: .init(body: Body(email: email))
            )
            return Self.startResult(reply)
        } catch {
            return .unreachable
        }
    }

    func verify(email: String, code: String) async -> VerifyResult {
        struct Body: Encodable { let step = "verify"; let email: String; let code: String }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "courtyard-connect", options: .init(body: Body(email: email, code: code))
            )
            return Self.verifyResult(reply)
        } catch {
            return .unreachable
        }
    }

    /// True once the server has deleted the session.
    func disconnect() async -> Bool {
        struct Reply: Decodable { let ok: Bool }
        do {
            let reply: Reply = try await Backend.client.functions.invoke(
                "courtyard-connect", options: .init(method: .delete)
            )
            return reply.ok
        } catch {
            return false
        }
    }

    // MARK: Reply mapping (pure, tested)

    struct Reply: Decodable, Equatable {
        let ok: Bool
        var error: String? = nil
        var emailHint: String? = nil
    }

    static func startResult(_ reply: Reply) -> StartResult {
        if reply.ok { return .sent }
        switch reply.error {
        case "invalid_email": return .invalidEmail
        case "rate_limited": return .rateLimited
        default: return .unreachable
        }
    }

    static func verifyResult(_ reply: Reply) -> VerifyResult {
        if reply.ok { return .connected(emailHint: reply.emailHint) }
        switch reply.error {
        case "invalid_code": return .invalidCode
        case "no_account": return .noAccount
        case "courtyard_rejected": return .rejected
        case "rate_limited": return .rateLimited
        // invalid_email at this step means the address changed under the code.
        case "invalid_email": return .invalidCode
        default: return .unreachable
        }
    }
}
