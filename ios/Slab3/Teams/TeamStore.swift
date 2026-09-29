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
                .from("teams").select("id, name, join_code").limit(1).execute().value
            if let row = teams.first {
                team = Team(id: row.id, name: row.name, joinCode: row.joinCode)
                members = try await Backend.client
                    .from("team_members").select("user_id, role, display_name")
                    .eq("team_id", value: row.id)
                    .order("joined_at").execute().value
            } else {
                team = nil
                members = []
            }
            lastLoadOK = true
        } catch {
            lastLoadOK = false
            // A failed load leaves the last known team in place. Teams must
            // degrade, never block (teams.md §2.7): scanning never waits on this.
        }
        loaded = true
    }

    /// Fill the store without a server — render tests and previews only.
    func seedForPreview(team: Team?, members: [Member], myUserId: UUID?) {
        self.team = team; self.members = members; self.myUserId = myUserId
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
            let _: JoinReply = try await Backend.client
                .rpc("join_team", params: ["p_code": JoinCode.normalized(code), "p_display_name": displayName])
                .execute().value
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

    /// Leave (member == me) or, for a lead, remove someone.
    func remove(_ member: Member) async -> String? {
        guard let team else { return nil }
        return await perform {
            try await Backend.client.rpc("remove_team_member", params: [
                "p_team_id": team.id.uuidString, "p_user_id": member.userId.uuidString,
            ]).execute()
        }
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
        } catch {
            return TeamError.copy(for: "network")
        }
    }

    // MARK: Wire shapes

    private struct TeamRow: Decodable {
        let id: UUID
        let name: String
        let joinCode: String
        enum CodingKeys: String, CodingKey { case id, name, joinCode = "join_code" }
    }
    private struct CreateReply: Decodable { let team_id: UUID }
    private struct JoinReply: Decodable { let team_id: UUID }
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
        case "already_in_team": return "You're already on a team. Leave it first."
        case "not_lead": return "Only a lead can do that."
        case "last_lead": return "A team needs a lead. Make someone else lead first."
        case "not_member": return "You're not on this team any more."
        case "not_authenticated": return "Signed out. Log in again."
        case "unavailable": return "Teams isn't available in this build."
        case "not_draft": return "Only a draft lot can be deleted. Close it instead."
        case "network": return "No connection. Nothing changed."
        default: return "That didn't go through. Nothing changed."
        }
    }
}
