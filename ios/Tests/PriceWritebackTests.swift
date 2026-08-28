import Testing
import Foundation
@testable import Slab3

/// The reported bug: a card that showed a price yesterday came up blank after a
/// refresh. Root cause was the write-back treating "couldn't reach the source"
/// the same as "the source has no price". These vectors pin the difference.
struct PriceWritebackTests {
    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let day1 = Date(timeIntervalSince1970: 1_700_086_400)

    private func priced(_ cents: Int) -> PriceWriteback.Stored {
        .init(cents: cents, asOf: day0, status: .ok)
    }

    @Test func unreachableKeepsTheLastKnownPrice() {
        let next = PriceWriteback.apply(.unreachable, to: priced(53_700), now: day1)
        #expect(next.cents == 53_700) // the bug: this used to be nil
        #expect(next.status == .unavailable)
        #expect(next.asOf == day0) // the date belongs to the number, not the attempt
    }

    @Test func repeatedFailuresNeverErodeThePrice() {
        var stored = priced(53_700)
        for _ in 0..<5 { stored = PriceWriteback.apply(.unreachable, to: stored, now: day1) }
        #expect(stored.cents == 53_700)
    }

    @Test func notListedClearsBecauseItIsAuthoritative() {
        let next = PriceWriteback.apply(.notListed, to: priced(53_700), now: day1)
        #expect(next.cents == nil)
        #expect(next.status == .notListed)
    }

    @Test func notConnectedClearsCardLadderPerToSGate() {
        let next = PriceWriteback.apply(.notConnected, to: priced(61_200), now: day1)
        #expect(next.cents == nil)
        #expect(next.status == .notConnected)
    }

    @Test func aFreshPriceStampsItsOwnDate() {
        let next = PriceWriteback.apply(.price(61_200), to: priced(53_700), now: day1)
        #expect(next.cents == 61_200)
        #expect(next.asOf == day1)
        #expect(next.status == .ok)
    }

    @Test func unreachableWithNothingStoredStaysEmpty() {
        let next = PriceWriteback.apply(.unreachable, to: .none, now: day1)
        #expect(next.cents == nil)
        #expect(next.status == .unavailable) // "couldn't check", not "not listed"
    }
}
