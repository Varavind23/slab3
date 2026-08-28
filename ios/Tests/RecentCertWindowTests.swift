import Testing
import Foundation
@testable import Slab3

/// Suppression is the only branching logic in the camera rebuild, and it is
/// load-bearing: the scanner reads barcodes off raw video frames, so a slab held
/// in frame re-detects about twelve times a second.
///
/// Two rules under test — identity first, then a short timer:
///   1. the same cert as the last one admitted never re-admits, however long the
///      gap, because that is the camera re-reading what is still in your hand;
///   2. any other recently-seen cert is held off by a short trailing window.
///
/// (`admit` is mutating, so each call is hoisted into a local — the `#expect`
/// macro can't call a mutating member inside its expansion.)
struct RecentCertWindowTests {
    private let key = "psa:49385027"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func firstSightingIsAdmitted() {
        var window = RecentCertWindow(suppression: 1.5)
        let first = window.admit(key, now: t0)
        #expect(first)
    }

    @Test func theSameSlabNeverReAdmitsWhileItIsTheLastOneSeen() {
        var window = RecentCertWindow(suppression: 1.5)
        _ = window.admit(key, now: t0)
        let immediately = window.admit(key, now: t0.addingTimeInterval(0.1))
        let muchLater = window.admit(key, now: t0.addingTimeInterval(600))
        #expect(!immediately)
        #expect(!muchLater, "no elapsed time makes it a different slab")
    }

    /// The case a timer alone gets wrong. Glare makes detection intermittent, so
    /// a label can go quiet for longer than any sane window and come back — while
    /// still being the same slab in the same hand. Under a pure timer that read
    /// as a new scan and fired a spurious "already in inventory".
    @Test func intermittentDetectionOfOneSlabNeverLooksLikeANewScan() {
        var window = RecentCertWindow(suppression: 1.5)
        _ = window.admit(key, now: t0)
        for gap in [0.2, 3.0, 4.5, 12.0] {
            let reappeared = window.admit(key, now: t0.addingTimeInterval(gap))
            #expect(!reappeared, "same slab reappearing after \(gap)s of glare")
        }
    }

    /// Moving on to another slab is the signal that you are done with the last
    /// one — and only then does coming back count as a deliberate rescan.
    @Test func aDifferentCertClearsTheHoldOnThePreviousOne() {
        var window = RecentCertWindow(suppression: 1.5)
        _ = window.admit(key, now: t0)
        let next = window.admit("psa:82031277", now: t0.addingTimeInterval(1))
        let backToFirst = window.admit(key, now: t0.addingTimeInterval(4))
        #expect(next)
        #expect(backToFirst, "a deliberate rescan should reach the duplicate check")
    }

    @Test func differentCertsDoNotSuppressEachOther() {
        var window = RecentCertWindow(suppression: 1.5)
        let psa = window.admit("psa:49385027", now: t0)
        let cgc = window.admit("cgc:6055074171", now: t0)
        let other = window.admit("psa:82031277", now: t0)
        #expect(psa)
        #expect(cgc)
        #expect(other)
    }

    /// Rule 2: two slabs sitting in frame together must not take turns
    /// re-triggering each other every time detection alternates.
    @Test func alternatingSlabsAreHeldOffByTheWindow() {
        var window = RecentCertWindow(suppression: 1.5)
        let a1 = window.admit("psa:A", now: t0)
        let b1 = window.admit("psa:B", now: t0.addingTimeInterval(0.1))
        let a2 = window.admit("psa:A", now: t0.addingTimeInterval(0.2))
        let b2 = window.admit("psa:B", now: t0.addingTimeInterval(0.3))
        #expect(a1)
        #expect(b1)
        #expect(!a2, "A was seen 0.2s ago")
        #expect(!b2)
    }

    /// Deleting a card has to make its slab immediately re-scannable, rather
    /// than leaving the user waiting out a window with no feedback.
    @Test func forgettingAllowsAnImmediateRescan() {
        var window = RecentCertWindow(suppression: 1.5)
        _ = window.admit(key, now: t0)
        window.forget(key)
        let rescanned = window.admit(key, now: t0.addingTimeInterval(0.1))
        #expect(rescanned)
    }

    /// A long sourcing session must not grow the map without bound.
    @Test func staleEntriesArePruned() {
        var window = RecentCertWindow(suppression: 1.5)
        for i in 0..<64 { _ = window.admit("psa:\(i)", now: t0) }
        _ = window.admit("psa:fresh", now: t0.addingTimeInterval(120))
        #expect(window.trackedCount < 64)
    }
}
