import Testing
import Foundation
@testable import Slab3

/// Suppression is the only branching logic in the camera rebuild, and it is
/// load-bearing: the scanner reads barcodes off raw video frames, so a slab held
/// in frame re-detects about twelve times a second.
///
/// Three rules under test — identity, then one-slab-at-a-time, then a short timer:
///   1. the same cert as the last one admitted never re-admits, however long the
///      gap, because that is the camera re-reading what is still in your hand;
///   2. nothing at all is admitted while the slab just captured is still in
///      frame, however many other codes are visible beside it;
///   3. once it has gone, any OTHER recently-seen cert is held off by a short
///      trailing window.
///
/// Rule 2 arrived with the duplicate-scan fix (2026-09-15): users work a reversed
/// stack and lift one slab at a time, so the slab coming off and the one beneath
/// it share the frame constantly.
///
/// (`admit`/`update` are mutating, so each call is hoisted into a local — the
/// `#expect` macro can't call a mutating member inside its expansion.)
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

    // MARK: Rule 2 — one slab at a time

    /// Was `differentCertsDoNotSuppressEachOther`, which asserted that three certs
    /// seen at the same instant were all admitted. That is the duplicate bug in
    /// miniature: a frame holding several labels is one slab being lifted off
    /// another, not three slabs presented to be scanned.
    @Test func onlyOneCertIsAdmittedFromOneFrame() {
        var window = RecentCertWindow(suppression: 1.5, clearance: 0.4)
        let first = window.update(sightings: ["psa:A", "psa:B", "cgc:C"], now: t0)
        let alsoInFrame = window.update(sightings: ["psa:B", "cgc:C"], now: t0.addingTimeInterval(0.1))
        #expect(first == "psa:A")
        #expect(alsoInFrame == nil, "the captured slab was in frame 0.1s ago")
    }

    /// The workflow this was written for: lift the top slab, exposing the next.
    /// Both are in frame together, and the one underneath must wait — but only
    /// until the lifted one is actually gone, or a fast sourcer is throttled.
    @Test func theNextSlabIsTakenAsSoonAsTheCapturedOneLeaves() {
        var window = RecentCertWindow(suppression: 1.5, clearance: 0.4)
        let captured = window.update(sightings: ["psa:A"], now: t0)
        let whileLifting = window.update(sightings: ["psa:A", "psa:B"], now: t0.addingTimeInterval(0.3))
        let afterItLeaves = window.update(sightings: ["psa:B"], now: t0.addingTimeInterval(0.8))
        #expect(captured == "psa:A")
        #expect(whileLifting == nil, "A is still in view")
        #expect(afterItLeaves == "psa:B", "B waited out the hold, not its own trailing window")
    }

    /// The deadlock this rule could easily have introduced: the next slab is in
    /// view for the WHOLE hold, so if every sighting counted, its trailing window
    /// would be pushed back on every pass and it could never be admitted at all.
    @Test func aSlabVisibleThroughoutTheHoldIsStillTakenAfterwards() {
        var window = RecentCertWindow(suppression: 1.5, clearance: 0.4)
        _ = window.update(sightings: ["psa:A", "psa:B"], now: t0)
        for tick in stride(from: 0.05, through: 0.35, by: 0.05) {
            _ = window.update(sightings: ["psa:A", "psa:B"], now: t0.addingTimeInterval(tick))
        }
        let next = window.update(sightings: ["psa:B"], now: t0.addingTimeInterval(0.9))
        #expect(next == "psa:B")
    }

    /// One slab can carry two readable codes, and they need not parse alike: a
    /// zero-padded barcode reads as a ten-digit CGC cert where the QR reads the
    /// eight-digit PSA one. While that slab is in frame only its first read is
    /// taken, so it cannot open a second row under a second identity.
    @Test func aSlabWithTwoReadableCodesIsAdmittedOnce() {
        var window = RecentCertWindow(suppression: 1.5, clearance: 0.4)
        let both = ["psa:49385027", "cgc:0049385027"]
        let first = window.update(sightings: both, now: t0)
        var admittedAgain: String?
        for tick in stride(from: 0.1, through: 2.0, by: 0.1) {
            if let again = window.update(sightings: both, now: t0.addingTimeInterval(tick)) {
                admittedAgain = again
            }
        }
        #expect(first == "psa:49385027")
        #expect(admittedAgain == nil, "the slab's other code must not open a second row")
    }

    /// The viewport tells the user which state the scanner is in, so holding and
    /// failing-to-read don't look alike. A blink of empty frames is not a lifted
    /// slab — that is what `clearance` is for.
    @Test func holdingIsReportedUntilTheSlabIsActuallyGone() {
        var window = RecentCertWindow(suppression: 1.5, clearance: 0.4)
        _ = window.update(sightings: ["psa:A"], now: t0)
        let holdsOnCapture = window.isHolding
        _ = window.update(sightings: [], now: t0.addingTimeInterval(0.2))
        let stillHolding = window.isHolding
        _ = window.update(sightings: [], now: t0.addingTimeInterval(0.5))
        let armedAgain = window.isHolding
        #expect(holdsOnCapture)
        #expect(stillHolding, "0.2s of empty frames is a blink, not a lifted slab")
        #expect(!armedAgain)
    }

    /// Rule 3 still earns its place once the hold is clear: two slabs left lying
    /// in frame must not take turns re-triggering each other.
    @Test func slabsLeftInFrameDoNotTakeTurns() {
        var window = RecentCertWindow(suppression: 1.5, clearance: 0.4)
        _ = window.update(sightings: ["psa:A"], now: t0)
        let b = window.update(sightings: ["psa:B"], now: t0.addingTimeInterval(0.5))
        let bAgain = window.update(sightings: ["psa:B"], now: t0.addingTimeInterval(1.0))
        #expect(b == "psa:B", "A had gone, so B is the slab being presented")
        #expect(bAgain == nil)
    }

    /// Tap-to-scan admits outside these rules — the user picked the slab — but it
    /// still tells the window what it took. Without that, flipping back to
    /// auto-scan with the tapped slab still in your hand would take it again.
    @Test func aTapAdmissionStillHoldsTheScanner() {
        var window = RecentCertWindow(suppression: 1.5, clearance: 0.4)
        window.noteAdmitted("psa:A", now: t0)
        let holdsImmediately = window.isHolding
        let stillInFrame = window.update(sightings: ["psa:A"], now: t0.addingTimeInterval(0.1))
        let neverRetaken = window.update(sightings: ["psa:A"], now: t0.addingTimeInterval(5))
        #expect(holdsImmediately)
        #expect(stillInFrame == nil)
        #expect(neverRetaken == nil, "rule 1 covers a tapped slab too")
    }

    // MARK: Housekeeping

    /// Deleting a card has to make its slab immediately re-scannable, rather
    /// than leaving the user waiting out a window with no feedback.
    @Test func forgettingAllowsAnImmediateRescan() {
        var window = RecentCertWindow(suppression: 1.5)
        _ = window.admit(key, now: t0)
        window.forget(key)
        let rescanned = window.admit(key, now: t0.addingTimeInterval(0.1))
        #expect(rescanned)
    }

    /// A long sourcing session must not grow the map without bound. Spaced a
    /// second apart so each slab is genuinely admitted rather than held.
    @Test func staleEntriesArePruned() {
        var window = RecentCertWindow(suppression: 1.5, clearance: 0.4)
        for i in 0..<64 { _ = window.admit("psa:\(i)", now: t0.addingTimeInterval(Double(i))) }
        _ = window.admit("psa:fresh", now: t0.addingTimeInterval(200))
        #expect(window.trackedCount < 64)
    }
}
