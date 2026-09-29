import Testing
import Foundation
@testable import Slab3

/// Teams: the pure parts of joining a team, and the kill switch that turns the
/// whole feature inert.
///
/// Teams is on in every build since 0.8. The switch is what an emergency build
/// would flip, so its off state must really be off: no team request, no team state.
/// Serialized because the switch is global.
@MainActor
@Suite(.serialized)
struct TeamsTests {

    // MARK: The kill switch

    @Test func teamsAreOnUnlessSwitchedOff() {
        #expect(TeamsFeature.isAvailable, "0.8: Teams is live")
        TeamsFeature.killSwitch = true
        defer { TeamsFeature.killSwitch = false }
        #expect(!TeamsFeature.isAvailable)
    }

    @Test func loadIsInertWhenTeamsAreOff() async {
        TeamsFeature.killSwitch = true
        defer { TeamsFeature.killSwitch = false }
        let store = TeamStore()
        await store.load()
        #expect(store.team == nil)
        #expect(store.members.isEmpty)
        #expect(store.myUserId == nil, "not even the session is read")
        #expect(!store.loaded, "so Settings never renders a Team section")
    }

    @Test func actionsRefuseWithoutAskingTheServer() async {
        TeamsFeature.killSwitch = true
        defer { TeamsFeature.killSwitch = false }
        let store = TeamStore()
        let failure = await store.join(code: "K7Q2MX", displayName: "Justin")
        #expect(failure == TeamError.copy(for: "unavailable"))
        #expect(!store.isWorking)
    }

    // MARK: The code as a person handles it

    @Test func codeDisplaysSplitForReadingAloud() {
        #expect(JoinCode.display("K7Q2MX") == "K7Q-2MX")
        #expect(JoinCode.display("ABC") == "ABC", "anything that isn't a stored code shows as-is")
    }

    @Test func codeAcceptsHoweverItIsTypedBack() {
        #expect(JoinCode.normalized("k7q-2mx") == "K7Q2MX")
        #expect(JoinCode.normalized(" K7Q 2MX ") == "K7Q2MX")
        #expect(JoinCode.normalized("k7q—2mx") == "K7Q2MX", "an em dash from autocorrect is dropped too")
    }

    @Test func codeIsCompleteAtSixCharacters() {
        #expect(JoinCode.isComplete("K7Q-2MX"))
        #expect(!JoinCode.isComplete("K7Q-2M"))
        #expect(!JoinCode.isComplete("K7Q-2MXX"))
        #expect(!JoinCode.isComplete("ñ7Q2MX"), "non-ASCII letters are not code symbols")
    }

    // MARK: Server errors become copy

    /// Every message the migration raises has its own sentence; only the unknown
    /// falls to the generic one. If a new raise is added to the SQL without copy,
    /// it shows the generic line rather than a machine code.
    @Test func everyRaisedCodeHasItsOwnCopy() {
        let generic = TeamError.copy(for: "something_new")
        for code in ["invalid_code", "already_in_team", "not_lead", "last_lead",
                     "not_member", "not_authenticated", "unavailable", "network"] {
            #expect(TeamError.copy(for: code) != generic, "\(code) needs its own copy")
        }
        #expect(!generic.contains("_"), "no machine code ever reaches the screen")
    }
}
