import Testing
import Foundation
@testable import Slab3

/// Teams phase 1: the pure parts of joining a team, and the gate that keeps the
/// whole feature inert on every build that is not pointed at the local stack.
///
/// The gate matters most. Teams' tables exist only locally until the owner ships
/// the migration, and users are live on the shipped app — so a normal build must
/// make no team request and hold no team state. The test host is launched without
/// SLABS_BACKEND=local, which is exactly the shipped condition.
@MainActor
struct TeamsTests {

    // MARK: The gate

    @Test func teamsAreOffWithoutTheLocalBackend() {
        #expect(!Backend.isLocal, "the test host runs against the live config, like a shipped build")
        #expect(!TeamsFeature.isAvailable)
    }

    @Test func loadIsInertWhenTeamsAreOff() async {
        let store = TeamStore()
        await store.load()
        #expect(store.team == nil)
        #expect(store.members.isEmpty)
        #expect(store.myUserId == nil, "not even the session is read")
        #expect(!store.loaded, "so Settings never renders a Team section")
    }

    @Test func actionsRefuseWithoutAskingTheServer() async {
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
