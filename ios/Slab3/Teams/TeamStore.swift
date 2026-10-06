import Foundation
import Observation
import Supabase

/// Whether any team code may run in this build.
///
/// Teams went live with 0.8 (owner, 2026-09-28): its migrations are on the live
/// project and every build may ask "am I on a team?" — one small request at launch.
/// Being ON a team is still what turns everything else on (AppTab.visible,
/// TeamStore.team): someone on no team gets the four-tab app with no team UI.
///
/// `killSwitch` is the one way to turn the whole feature off in a build — tests use
/// it to prove the off state stays inert (no request, no state), and it is where an
/// emergency build would flip it. Before 0.8 this was `Backend.isLocal`.
enum TeamsFeature {
    nonisolated(unsafe) static var killSwitch = false
    static var isAvailable: Bool { !killSwitch }
}

/// The signed-in user's team, if they are on one (one team per user — enforced by
/// `team_members_user_id_key` in the migration).
///
/// Being on a team IS the gate for every other team feature (plan §4b): a nil
/// `team` means zero lot calls and zero lot UI anywhere in the app.
@MainActor
@Observable
final class TeamStore {
    struct Team: Equatable {
        let id: UUID
        var name: String
        var joinCode: String
        /// The lead's max-buy settings for the whole team (owner M2, 2026-10-01).
        /// nil until set — members then price on their own phone's defaults. Set,
        /// they REPLACE a member's skew and margin on every card, and a member's
        /// per-card sliders may only go higher (a lower offer), never lower.
        var maxBuySkew: Double? = nil
        var maxBuyMargin: Double? = nil

        /// Both set, or no team setting at all — a half-set pair is not a policy.
        var maxBuy: (skew: Double, margin: Double)? {
            guard let maxBuySkew, let maxBuyMargin else { return nil }
            return (maxBuySkew, maxBuyMargin)
        }
    }

    struct Member: Equatable, Identifiable, Decodable {
        let userId: UUID
        var role: TeamRole
        var displayName: String
        var id: UUID { userId }

        enum CodingKeys: String, CodingKey {
            case userId = "user_id", role, displayName = "display_name"
        }
    }

    enum TeamRole: String, Decodable, Equatable { case lead, buyer }

    private(set) var team: Team?
    private(set) var members: [Member] = []
    /// The roster beyond the members: virtual members, consignors linked to an
    /// account, and the rows of members that credit has been given to (V1).
    private(set) var people: [TeamPerson] = []
    /// Teams this account is linked to as a CONSIGNOR (my_links) — nothing to do
    /// with being on a team. Asked only when Settings opens, never at launch.
    private(set) var links: [PersonLink] = []
    private(set) var myUserId: UUID?
    /// First load finished — distinguishes "not on a team" from "not asked yet",
    /// so Settings never flashes "Join or create a team" at someone who is on one.
    private(set) var loaded = false
    /// The LAST load reached the server. Only then may a nil `team` be believed —
    /// a failed load at a show with no signal must never read as "left the team"
    /// and detach every lot group (LotFolders.sync).
    private(set) var lastLoadOK = false
    private(set) var isWorking = false

    var me: Member? { members.first { $0.userId == myUserId } }
    var isLead: Bool { me?.role == .lead }
    var leads: [Member] { members.filter { $0.role == .lead } }

    // MARK: Load

    func load() async {
        guard TeamsFeature.isAvailable else { return }
        do {
            let uid = try await Backend.client.auth.session.user.id
            myUserId = uid
            // RLS returns only the caller's own team, so "the first row" is the team.
            let teams: [TeamRow] = try await Backend.client
                .from("teams").select("id, name, join_code, max_buy_skew, max_buy_margin").limit(1).execute().value
            if let row = teams.first {
                team = Team(id: row.id, name: row.name, joinCode: row.joinCode,
                            maxBuySkew: row.maxBuySkew, maxBuyMargin: row.maxBuyMargin)
                members = try await Backend.client
                    .from("team_members").select("user_id, role, display_name")
                    .eq("team_id", value: row.id)
                    .order("joined_at").execute().value
                var roster: [TeamPerson] = try await Backend.client
                    .from("team_people").select("id, team_id, display_name, user_id, link_code_at")
                    .eq("team_id", value: row.id)
                    .order("display_name").execute().value
                // The note is the lead's alone — the column is not granted to members
                // (20261004000000), so a lead asks for it separately.
                if members.contains(where: { $0.userId == uid && $0.role == .lead }) {
                    struct NoteRow: Decodable { let id: UUID; let note: String? }
                    let notes: [NoteRow] = try await Backend.client
                        .rpc("team_people_notes", params: ["p_team_id": row.id.uuidString]).execute().value
                    let byId = Dictionary(notes.map { ($0.id, $0.note) }, uniquingKeysWith: { a, _ in a })
                    for i in roster.indices { roster[i].note = byId[roster[i].id] ?? nil }
                }
                people = roster
            } else {
                team = nil
                members = []
                people = []
            }
            MaxBuyDefaults.team = team?.maxBuy
            // Kept for a launch with no signal (MaxBuyTeamPolicy.restore).
            MaxBuyTeamPolicy.shared.remember()
            lastLoadOK = true
        } catch {
            lastLoadOK = false
            // A failed load leaves the last known team in place. Teams must
            // degrade, never block (teams.md §2.7): scanning never waits on this.
        }
        loaded = true
    }

    /// Fill the store without a server — render tests and previews only.
    func seedForPreview(team: Team?, members: [Member], myUserId: UUID?, people: [TeamPerson] = []) {
        self.team = team; self.members = members; self.myUserId = myUserId; self.people = people
        MaxBuyDefaults.team = team?.maxBuy
        loaded = true; lastLoadOK = true
    }

    // MARK: Actions — each returns user-facing copy on failure, nil on success.

    func create(name: String, displayName: String) async -> String? {
        await perform {
            let _: CreateReply = try await Backend.client
                .rpc("create_team", params: ["p_name": name, "p_display_name": displayName])
                .execute().value
        }
    }

    func join(code: String, displayName: String) async -> String? {
        await perform {
            let reply: JoinReply = try await Backend.client
                .rpc("join_team", params: ["p_code": JoinCode.normalized(code), "p_display_name": displayName])
                .execute().value
            // A wrong code and too many guesses come back as data, not a raise:
            // the server counts failed guesses, and a raise would undo the count
            // (migration 20260930000000, owner decision D3).
            if let error = reply.error { throw JoinRefused(code: error) }
        }
    }

    func rotateCode() async -> String? {
        guard let team else { return nil }
        return await perform {
            try await Backend.client.rpc("rotate_team_code", params: ["p_team_id": team.id.uuidString]).execute()
        }
    }

    func setRole(_ role: TeamRole, for member: Member) async -> String? {
        guard let team else { return nil }
        return await perform {
            try await Backend.client.rpc("set_member_role", params: [
                "p_team_id": team.id.uuidString, "p_user_id": member.userId.uuidString, "p_role": role.rawValue,
            ]).execute()
        }
    }

    func setDisplayName(_ name: String) async -> String? {
        guard let team else { return nil }
        return await perform {
            try await Backend.client.rpc("set_display_name", params: [
                "p_team_id": team.id.uuidString, "p_display_name": name,
            ]).execute()
        }
    }

    /// The lead's team-wide skew and margin; nil, nil clears them so members price
    /// on their own defaults again. A plain update: `teams_rename` already limits it
    /// to the lead, and the migration grants exactly these two columns.
    func setMaxBuy(skew: Double?, margin: Double?) async -> String? {
        guard let team else { return nil }
        struct Update: Encodable {
            let max_buy_skew: Double?, max_buy_margin: Double?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(max_buy_skew, forKey: .max_buy_skew)     // nil → JSON null, which clears
                try c.encode(max_buy_margin, forKey: .max_buy_margin)
            }
            enum CodingKeys: String, CodingKey { case max_buy_skew, max_buy_margin }
        }
        return await perform {
            try await Backend.client.from("teams")
                .update(Update(max_buy_skew: skew, max_buy_margin: margin))
                .eq("id", value: team.id).execute()
        }
    }

    /// Leave (member == me) or, for a lead, remove someone.
    func remove(_ member: Member) async -> String? {
        guard let team else { return nil }
        return await perform {
            try await Backend.client.rpc("remove_team_member", params: [
                "p_team_id": team.id.uuidString, "p_user_id": member.userId.uuidString,
            ]).execute()
        }
    }

    // MARK: Virtual members (V1–V6) — lead-only on the server; each reloads.

    /// Who a slab can be credited to, for the tag pickers.
    var buyerChoices: [Buyer] { BuyerResolver.choices(members: members, people: people) }

    func addPerson(name: String, note: String?) async -> String? {
        guard let team else { return nil }
        return await perform {
            try await Backend.client.rpc("add_person", params: [
                "p_team_id": team.id.uuidString, "p_display_name": name, "p_note": note ?? "",
            ]).execute()
        }
    }

    func updatePerson(_ person: TeamPerson, name: String, note: String?) async -> String? {
        await perform {
            try await Backend.client.rpc("update_person", params: [
                "p_person_id": person.id.uuidString, "p_display_name": name, "p_note": note ?? "",
            ]).execute()
        }
    }

    func removePerson(_ person: TeamPerson) async -> String? {
        await perform {
            try await Backend.client.rpc("remove_person", params: ["p_person_id": person.id.uuidString]).execute()
        }
    }

    /// The person id to credit for a picked buyer: a person's own id, or the
    /// member's row, made on first use (member_person). nil + copy on failure.
    func personId(for buyer: Buyer) async -> (UUID?, String?) {
        if let id = BuyerResolver.personId(for: buyer, people: people) { return (id, nil) }
        guard let team else { return (nil, nil) }
        do {
            let id: UUID = try await Backend.client.rpc("member_person", params: [
                "p_team_id": team.id.uuidString, "p_user_id": buyer.id.uuidString,
            ]).execute().value
            await load()
            return (id, nil)
        } catch let error as PostgrestError {
            return (nil, TeamError.copy(for: error.message))
        } catch {
            return (nil, TeamError.copy(for: "network"))
        }
    }

    struct Invite: Equatable, Decodable {
        let code: String
        let expiresAt: String
        enum CodingKeys: String, CodingKey { case code, expiresAt = "expires_at" }
        var expiresDate: Date? { ISO8601.date(expiresAt) }
    }

    /// The person's invite code — the same one while it is valid, unless `rotate`.
    func invite(_ person: TeamPerson, rotate: Bool = false) async -> Result<Invite, InviteFailure> {
        guard TeamsFeature.isAvailable else { return .failure(.init(TeamError.copy(for: "unavailable"))) }
        do {
            struct Params: Encodable { let p_person_id: UUID; let p_rotate: Bool }
            let invite: Invite = try await Backend.client
                .rpc("invite_person", params: Params(p_person_id: person.id, p_rotate: rotate))
                .execute().value
            await load()
            return .success(invite)
        } catch let error as PostgrestError {
            return .failure(.init(TeamError.copy(for: error.message)))
        } catch {
            return .failure(.init(TeamError.copy(for: "network")))
        }
    }
    struct InviteFailure: Error, Equatable { let copy: String; init(_ copy: String) { self.copy = copy } }

    /// `absorb` disappears into `keep`; every slab credited to it follows.
    func merge(keep: TeamPerson, absorb: TeamPerson) async -> String? {
        await perform {
            try await Backend.client.rpc("merge_people", params: [
                "p_keep_id": keep.id.uuidString, "p_absorb_id": absorb.id.uuidString,
            ]).execute()
        }
    }

    func unlink(_ person: TeamPerson) async -> String? {
        await perform {
            try await Backend.client.rpc("unlink_person", params: ["p_person_id": person.id.uuidString]).execute()
        }
    }

    // MARK: The consignor's side (V5) — needs no team.

    func loadLinks() async {
        guard TeamsFeature.isAvailable else { return }
        if let rows: [PersonLink] = try? await Backend.client.rpc("my_links").execute().value {
            links = rows
        }
    }

    /// Enter a lead's invite code. Wrong codes come back as `{error}` (counted on the
    /// server, so they cannot be raised — link_person's header).
    func link(code: String) async -> String? {
        guard TeamsFeature.isAvailable else { return TeamError.copy(for: "unavailable") }
        struct Reply: Decodable { let error: String?; let team_name: String? }
        isWorking = true
        defer { isWorking = false }
        do {
            let reply: Reply = try await Backend.client
                .rpc("link_person", params: ["p_code": JoinCode.normalized(code)]).execute().value
            if let error = reply.error { return TeamError.copy(for: error == "invalid_code" ? "invalid_link_code" : error) }
            await loadLinks()
            return nil
        } catch let error as PostgrestError {
            return TeamError.copy(for: error.message)
        } catch {
            return TeamError.copy(for: "network")
        }
    }

    func unlinkMine(_ link: PersonLink) async -> String? {
        guard TeamsFeature.isAvailable else { return TeamError.copy(for: "unavailable") }
        do {
            try await Backend.client.rpc("unlink_person", params: ["p_person_id": link.personId.uuidString]).execute()
            await loadLinks()
            return nil
        } catch let error as PostgrestError {
            return TeamError.copy(for: error.message)
        } catch {
            return TeamError.copy(for: "network")
        }
    }

    func creditedCards() async -> [CreditedCard]? {
        guard TeamsFeature.isAvailable else { return nil }
        return try? await Backend.client.rpc("my_credited_cards").execute().value
    }

    /// Every mutation reloads afterwards rather than patching local state: the
    /// server owns roles, codes and membership, and a reload is one request.
    private func perform(_ work: () async throws -> Void) async -> String? {
        guard TeamsFeature.isAvailable else { return TeamError.copy(for: "unavailable") }
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            await load()
            return nil
        } catch let error as PostgrestError {
            return TeamError.copy(for: error.message)
        } catch let refused as JoinRefused {
            return TeamError.copy(for: refused.code)
        } catch {
            return TeamError.copy(for: "network")
        }
    }

    private struct JoinRefused: Error { let code: String }

    // MARK: Wire shapes

    private struct TeamRow: Decodable {
        let id: UUID
        let name: String
        let joinCode: String
        let maxBuySkew: Double?
        let maxBuyMargin: Double?
        enum CodingKeys: String, CodingKey {
            case id, name, joinCode = "join_code", maxBuySkew = "max_buy_skew", maxBuyMargin = "max_buy_margin"
        }
    }
    private struct CreateReply: Decodable { let team_id: UUID }
    /// `team_id` on success; `error` (`invalid_code`, `too_many_attempts`) when
    /// the server turned the code away.
    private struct JoinReply: Decodable { let team_id: UUID?; let error: String? }
}

/// The team code as a person handles it. Stored bare (`K7Q2MX`, the migration's
/// check constraint), shown split (`K7Q-2MX`) because it gets read aloud across a
/// card-show table, and accepted however it is typed back.
enum JoinCode {
    static func display(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3))-\(code.suffix(3))"
    }

    /// Mirrors join_team's own normalisation — upper case, only letters and
    /// digits — so what the field shows as complete is what the server accepts.
    static func normalized(_ typed: String) -> String {
        String(typed.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            .map(Character.init))
    }

    static func isComplete(_ typed: String) -> Bool { normalized(typed).count == 6 }
}

/// The RPCs raise machine-readable messages (`raise exception 'not_lead'`); this is
/// the one place they become copy. States what happened, without apology (Caliper).
enum TeamError {
    static func copy(for code: String) -> String {
        switch code {
        case "invalid_code": return "No team has that code. Check it with your lead."
        case "too_many_attempts": return "Too many wrong codes. Try again in an hour."
        case "range_has_buys": return "That bucket already holds buys. It stays."
        case "range_lot_fixed": return "A bucket can't move to another lot."
        case "already_in_team": return "You're already on a team. Leave it first."
        case "not_lead": return "Only a lead can do that."
        case "last_lead": return "A team needs a lead. Make someone else lead first."
        case "not_member": return "You're not on this team any more."
        case "not_authenticated": return "Signed out. Log in again."
        case "unavailable": return "Teams isn't available in this build."
        case "not_draft", "has_buys": return "This lot has buys. Archive it instead."
        case "network": return "No connection. Nothing changed."
        case "invalid_link_code": return "That code isn't valid. Codes work once and expire after 7 days."
        case "too_many_attempts": return "Too many wrong codes. Try again in an hour."
        case "already_linked": return "Already linked to this team."
        case "has_credit": return "They have cards tagged to them. Merge them into someone, or untag the cards first."
        case "linked_to_different_accounts": return "Both are linked to different accounts — they're two people."
        case "is_member": return "They're on the team. Remove them from the team instead."
        case "not_on_team": return "That person isn't on this team."
        default: return "That didn't go through. Nothing changed."
        }
    }
}
