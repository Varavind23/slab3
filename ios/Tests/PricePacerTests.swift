import Testing
import Foundation
@testable import Slab3

/// A pasted list is priced one card at a time with a gap — the pacing bulk
/// refresh lacked when it was removed (2026-09-16).
@MainActor
struct PricePacerTests {
    /// A pacer whose work and sleeps are recorded, not done.
    private final class Log { var events: [String] = [] }

    private func pacer(_ log: Log, gap: Duration = .milliseconds(1100)) -> PricePacer {
        let pacer = PricePacer()
        pacer.perform = { id, _ in log.events.append("price \(id.uuidString.prefix(4))") }
        pacer.sleep = { duration in log.events.append("sleep \(duration.components.seconds)s\(duration.components.attoseconds / 1_000_000_000_000_000)ms") }
        pacer.gap = { gap }
        return pacer
    }

    private func id(_ prefix: String) -> UUID { UUID(uuidString: "\(prefix)0000-0000-0000-0000-000000000000")! }

    @Test func pricesOneAtATimeInPasteOrderWithAGapAfterEach() async {
        let log = Log()
        let pacer = pacer(log)
        pacer.enqueue([id("AAAA"), id("BBBB"), id("CCCC")])
        await pacer.drain()
        #expect(log.events == [
            "price AAAA", "sleep 1s100ms",
            "price BBBB", "sleep 1s100ms",
            "price CCCC", "sleep 1s100ms",
        ], "the last card's gap too: a second list pasted right behind must not land inside it")
        #expect(pacer.isIdle)
    }

    @Test func aCardQueuedTwiceIsPricedOnce() async {
        let log = Log()
        let pacer = pacer(log)
        pacer.enqueue([id("AAAA"), id("BBBB"), id("AAAA")])
        await pacer.drain()
        #expect(log.events.filter { $0.hasPrefix("price") } == ["price AAAA", "price BBBB"])
    }

    @Test func aSecondListJoinsTheSameQueue() async {
        let log = Log()
        let pacer = pacer(log)
        pacer.enqueue([id("AAAA")])
        pacer.enqueue([id("BBBB")])
        #expect(pacer.pending.count == 2, "nothing has run yet — both wait in one queue")
        await pacer.drain()
        #expect(log.events.filter { $0.hasPrefix("price") } == ["price AAAA", "price BBBB"])
    }

    /// Card Ladder's ≤1 req/sec is what the long gap is for; a Courtyard-only
    /// run doesn't crawl.
    @Test func theGapFollowsTheCardLadderConnection() {
        #expect(PricePacer.cardLadderGap >= .seconds(1))
        #expect(PricePacer.courtyardGap < PricePacer.cardLadderGap)
    }
}
