import Testing
import Foundation
@testable import Slab3

/// Tap-to-scan's arm is a small state machine with a deadline, and both of its
/// edges are user-visible: a tap that never fires reads as a broken scanner, and
/// an arm that never expires means a tap can be answered a minute later by
/// whatever slab happens to drift past.
struct TapCaptureArmTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func anUnarmedScannerIgnoresEverything() {
        var arm = TapCaptureArm(window: 1.2)
        let withACert = arm.resolve(sawCert: true, now: t0)
        let without = arm.resolve(sawCert: false, now: t0)
        #expect(withACert == .idle, "auto-scan's frames must not capture in tap mode")
        #expect(without == .idle)
    }

    @Test func aTapTakesTheNextFrameThatHoldsACert() {
        var arm = TapCaptureArm(window: 1.2)
        arm.arm(now: t0)
        let outcome = arm.resolve(sawCert: true, now: t0.addingTimeInterval(0.08))
        #expect(outcome == .capture)
    }

    /// One tap, one slab. The arm is consumed by the capture, or a single tap
    /// would keep taking cards for as long as the deadline lasted.
    @Test func oneTapCapturesOnce() {
        var arm = TapCaptureArm(window: 1.2)
        arm.arm(now: t0)
        let first = arm.resolve(sawCert: true, now: t0.addingTimeInterval(0.08))
        let second = arm.resolve(sawCert: true, now: t0.addingTimeInterval(0.16))
        #expect(first == .capture)
        #expect(second == .idle)
        #expect(!arm.isArmed)
    }

    /// The label needs a moment to come into focus, so a tap keeps looking rather
    /// than answering on the first empty frame.
    @Test func aTapKeepsLookingUntilItsDeadline() {
        var arm = TapCaptureArm(window: 1.2)
        arm.arm(now: t0)
        let early = arm.resolve(sawCert: false, now: t0.addingTimeInterval(0.3))
        let late = arm.resolve(sawCert: false, now: t0.addingTimeInterval(1.1))
        let caught = arm.resolve(sawCert: true, now: t0.addingTimeInterval(1.15))
        #expect(early == .idle)
        #expect(late == .idle)
        #expect(caught == .capture, "still inside the window")
    }

    /// A tap is a question and gets an answer — unlike auto-scan, where silence
    /// was honest because nothing had been asked.
    @Test func aTapWithNothingInFrameExpiresAndSaysSo() {
        var arm = TapCaptureArm(window: 1.2)
        arm.arm(now: t0)
        let outcome = arm.resolve(sawCert: false, now: t0.addingTimeInterval(1.2))
        #expect(outcome == .expired)
        #expect(!arm.isArmed)
    }

    /// Expiry is reported once, not on every frame after the deadline.
    @Test func expiryIsReportedOnce() {
        var arm = TapCaptureArm(window: 1.2)
        arm.arm(now: t0)
        let first = arm.resolve(sawCert: false, now: t0.addingTimeInterval(1.5))
        let second = arm.resolve(sawCert: false, now: t0.addingTimeInterval(1.6))
        #expect(first == .expired)
        #expect(second == .idle)
    }

    /// Switching back to auto-scan, or leaving the screen, must not leave a tap
    /// pending that fires a readout into a different mode.
    @Test func cancellingDropsAPendingTap() {
        var arm = TapCaptureArm(window: 1.2)
        arm.arm(now: t0)
        arm.cancel()
        let outcome = arm.resolve(sawCert: true, now: t0.addingTimeInterval(0.1))
        #expect(outcome == .idle)
        #expect(!arm.isArmed)
    }
}
