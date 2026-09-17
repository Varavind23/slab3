import Foundation

/// Tap-to-scan's one-shot arm.
///
/// WHY A TAP DOES NOT CAPTURE ON THE SPOT. The pixel buffer is only valid inside
/// the camera's delegate callback and is never retained past it (`SlabFrameCapture`
/// explains what retaining costs: a starved capture pool and the stall the whole
/// rebuild exists to remove). A tap arriving on the main actor therefore cannot
/// reach back for pixels that have already been recycled. So a tap ARMS the next
/// detection pass instead, and the pass that finds a cert encodes THAT frame — at
/// twelve passes a second the wait is one or two frames, which is imperceptible,
/// and the photo is still the frame the barcode was actually read in.
///
/// It also answers a question auto-scan never had to. Under auto-scan the scanner
/// either read a cert or said nothing, and silence was honest — nothing had been
/// asked. A tap IS a question, so it gets an answer: if nothing readable turns up
/// within `window`, the arm expires and the screen says so.
struct TapCaptureArm {
    enum Outcome: Equatable {
        /// Not armed, or armed and still looking. Nothing to do.
        case idle
        /// Armed and a cert is in this frame: take it.
        case capture
        /// Armed, and nothing readable turned up in time. Tell the user.
        case expired
    }

    /// How long one tap keeps looking. Long enough to cover a refocus or a hand
    /// settling, short enough that the answer still belongs to the tap that asked.
    var window: TimeInterval = 1.2

    private var armedAt: Date?

    init(window: TimeInterval = 1.2) {
        self.window = window
    }

    var isArmed: Bool { armedAt != nil }

    mutating func arm(now: Date = Date()) { armedAt = now }

    /// Disarm without an answer — switching modes, or leaving the screen. A tap
    /// the user has walked away from must not fire a readout later.
    mutating func cancel() { armedAt = nil }

    /// One detection pass. `sawCert` is whether this frame holds a readable cert.
    mutating func resolve(sawCert: Bool, now: Date = Date()) -> Outcome {
        guard let armedAt else { return .idle }
        if sawCert {
            self.armedAt = nil
            return .capture
        }
        if now.timeIntervalSince(armedAt) >= window {
            self.armedAt = nil
            return .expired
        }
        return .idle
    }
}
