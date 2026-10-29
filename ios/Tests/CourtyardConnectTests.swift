import Foundation
import Testing
@testable import Slab3

/// Courtyard became bring-your-own-account on 2026-10-29 (spike/README.md §2g):
/// the scanner answers only to a logged-in Courtyard account. These pin how the
/// app reads the server's new answers — a wrong mapping either shows Courtyard
/// data to an unconnected user or blanks a connected user's prices over a blip.
struct CourtyardConnectTests {

    // MARK: courtyard-price replies

    @Test func notConnectedAndExpiredAreTheirOwnOutcomes() {
        guard case .notConnected = CourtyardScannerClient.outcome(.init(status: "not_connected")) else {
            Issue.record("not_connected must not read as unavailable"); return
        }
        guard case .authExpired = CourtyardScannerClient.outcome(.init(status: "auth_expired")) else {
            Issue.record("auth_expired must not read as unavailable"); return
        }
    }

    @Test func aTransientFailureStillKeepsThePrice() {
        // source_error is what the server says for a refresh blip or a lease held
        // elsewhere; it must stay .unavailable, which keeps the last value.
        guard case .unavailable = CourtyardScannerClient.outcome(.init(status: "source_error")) else {
            Issue.record("source_error must stay transient"); return
        }
    }

    @Test func aPricedReplyIsUnchanged() {
        guard case .ok(let price, _, _) = CourtyardScannerClient.outcome(
            .init(status: "ok", priceCents: 9130, confidence: 3)) else {
            Issue.record("ok must price"); return
        }
        #expect(price.valueCents == 9130)
        #expect(price.confidence == 3)
    }

    // MARK: courtyard-connect replies

    @Test func startMapsTheServersErrors() {
        typealias R = CourtyardAccountClient.Reply
        #expect(CourtyardAccountClient.startResult(R(ok: true)) == .sent)
        #expect(CourtyardAccountClient.startResult(R(ok: false, error: "invalid_email")) == .invalidEmail)
        #expect(CourtyardAccountClient.startResult(R(ok: false, error: "rate_limited")) == .rateLimited)
        #expect(CourtyardAccountClient.startResult(R(ok: false, error: "courtyard_unreachable")) == .unreachable)
    }

    @Test func verifyMapsTheServersErrors() {
        typealias R = CourtyardAccountClient.Reply
        #expect(CourtyardAccountClient.verifyResult(R(ok: true, emailHint: "s•••@example.com"))
                == .connected(emailHint: "s•••@example.com"))
        #expect(CourtyardAccountClient.verifyResult(R(ok: false, error: "invalid_code")) == .invalidCode)
        #expect(CourtyardAccountClient.verifyResult(R(ok: false, error: "no_account")) == .noAccount)
        #expect(CourtyardAccountClient.verifyResult(R(ok: false, error: "courtyard_rejected")) == .rejected)
        // Anything new is "couldn't reach", never "your code was wrong".
        #expect(CourtyardAccountClient.verifyResult(R(ok: false, error: "something_new")) == .unreachable)
    }

    // MARK: Teams

    @Test func aCourtyardLotNamesCourtyardWhenTheBuyerIsNotConnected() {
        let noCY = LotVerdict(outcome: "pending", reason: "cy_not_connected")
        let line = LotVerdictText.line(state: .pending, verdict: noCY)
        #expect(line.text == "Lot · connect Courtyard to claim")
        #expect(line.tone == .warn)
    }
}
