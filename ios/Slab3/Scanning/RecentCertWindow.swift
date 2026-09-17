import Foundation

/// Decides which sightings are worth reacting to, and keeps the scanner on ONE
/// slab at a time.
///
/// This exists because the rebuilt scanner reads barcodes off the raw video
/// stream, and Vision has no notion of a tracked item: a slab held in frame
/// re-detects on EVERY pass, ~12 times a second, so without it one slab would
/// buzz and flash a dozen times while you hold it.
///
/// What it does NOT do is prevent a duplicate ROW: `CardLookup.existing` checks
/// the store unconditionally and `ScanScreen.add` refuses a cert it already has.
/// All this decides is whether a sighting is worth REACTING to.
///
/// It replaces a `Set` that lived for the life of the scan session, which erred
/// the other way: a cert once seen could never be scanned again, so a deliberate
/// re-scan did nothing at all and never reached the "already in inventory" check
/// that would have explained why.
///
/// Three rules, because no one of them covers the workflow on its own:
///
///   1. The same cert as the last one admitted is never admitted again. A slab
///      does not get deliberately rescanned twice in a row with nothing in
///      between — so a repeat is the camera re-reading what is still in your
///      hand, however long the gap. This is what makes intermittent detection
///      safe: a glare-obscured label that goes quiet for four seconds and comes
///      back is still the same slab, and a timer alone would treat it as new.
///
///   2. **One slab at a time.** Nothing at all is admitted while the slab just
///      captured is still in view — not another cert, not a second code on the
///      same slab. The scanner re-arms only once that slab has gone unseen for
///      `clearance`. Added 2026-09-15: users work a reversed stack, lifting one
///      slab off at a time, so the slab being lifted and the one beneath it share
///      the frame constantly. Under rules 1 and 3 alone the newly exposed slab was
///      admitted while the lifted one was still being read, and a slab whose
///      second code (QR vs barcode) parsed to a different cert could be admitted
///      twice — both of which put the same card in the recent list more than once.
///      This rule needs the WHOLE frame every pass, which is why
///      `BarcodeDetector.certificates` returns every cert rather than the first.
///
///   3. Any other cert seen recently is suppressed by a short trailing window,
///      which every sighting pushes back. This still matters once the hold has
///      cleared: it stops two slabs left lying in frame from taking turns.
///
/// Rule 1 is why the window can be as short as it is: the long tail it used to
/// have to cover is handled by identity instead of by waiting.
struct RecentCertWindow {
    /// How long a DIFFERENT cert stays suppressed after being seen. Only has to
    /// cover slabs alternating in frame, since a repeat of the last one is
    /// blocked outright — so it is short on purpose.
    var suppression: TimeInterval = 1.5

    /// How long the captured slab must go UNSEEN before the scanner takes the
    /// next one. About five detection passes at 12/s: long enough to ride out a
    /// frame or two lost to glare while the slab is still in hand, short enough
    /// that lifting it away and presenting the next one feels immediate.
    var clearance: TimeInterval = 0.4

    /// Entries older than this are dropped, so a long session doesn't grow the
    /// dictionary without bound.
    private let pruneAfter: TimeInterval = 60

    private var seen: [String: Date] = [:]

    /// The cert most recently admitted. Rule 1 above.
    private var lastAdmitted: String?

    /// True while the scanner is holding on the slab it just captured (rule 2).
    /// The UI reads this to say so — a scanner that is deliberately ignoring the
    /// code in front of you must not look like one that is failing to read it.
    private(set) var isHolding = false

    init(suppression: TimeInterval = 1.5, clearance: TimeInterval = 0.4) {
        self.suppression = suppression
        self.clearance = clearance
    }

    /// One detection pass: every cert visible in this frame, which may be none.
    ///
    /// Call it on EVERY pass, including empty ones — an empty frame is precisely
    /// the evidence that the captured slab has left and the scanner can re-arm.
    /// Returns the cert to react to, or nil.
    @discardableResult
    mutating func update(sightings: [String], now: Date = Date()) -> String? {
        prune(now: now)

        // Rule 2. While the hold is up the captured slab is the ONLY sighting
        // recorded — and in a pass that admits something, only the cert admitted
        // is. Every other code in the frame is background: the slab underneath
        // the one being lifted is in view the entire time, so recording it would
        // push its own trailing window (rule 3) back on every pass, and the user
        // would wait out a suppression meant for a case this is not. It cost a
        // second of dead air per slab before a test caught it.
        if let last = lastAdmitted {
            if sightings.contains(last) { seen[last] = now }
            if let at = seen[last], now.timeIntervalSince(at) < clearance {
                isHolding = true
                return nil
            }
        }
        isHolding = false

        // Armed. Rule 1 is the `where` clause: a repeat of the last cert admitted
        // is the slab still in your hand, and only a different cert clears it.
        for key in sightings where key != lastAdmitted {
            // Rule 3: a different cert, but one seen a moment ago.
            if let previous = seen[key], now.timeIntervalSince(previous) < suppression { continue }
            seen[key] = now
            lastAdmitted = key
            isHolding = true
            return key
        }

        // Nothing to react to, so the frame is only evidence of what is lying in
        // view — record it, which is what keeps a hovering slab's trailing window
        // pushed back.
        for key in sightings where key != lastAdmitted { seen[key] = now }
        return nil
    }

    /// True if this cert should be accepted as a new scan right now.
    /// Always records the sighting, whether or not it was admitted.
    mutating func admit(_ key: String, now: Date = Date()) -> Bool {
        update(sightings: [key], now: now) == key
    }

    /// Record an admission this window did not make.
    ///
    /// Tap-to-scan bypasses the rules above on purpose — the user picked the slab,
    /// so a second tap on one already in inventory must reach the duplicate
    /// readout rather than be swallowed by rule 1. The bookkeeping still has to
    /// happen, or switching back to auto-scan would immediately re-take the slab
    /// still sitting in your hand.
    mutating func noteAdmitted(_ key: String, now: Date = Date()) {
        seen[key] = now
        lastAdmitted = key
        isHolding = true
    }

    /// Forget a cert immediately — used when its card is deleted, so the same
    /// slab can be re-scanned without waiting out the window.
    mutating func forget(_ key: String) {
        seen.removeValue(forKey: key)
        if lastAdmitted == key {
            lastAdmitted = nil
            isHolding = false
        }
    }

    mutating func removeAll() {
        seen.removeAll()
        lastAdmitted = nil
        isHolding = false
    }

    private mutating func prune(now: Date) {
        guard seen.count > 32 else { return }
        seen = seen.filter { now.timeIntervalSince($0.value) < pruneAfter }
    }

    var trackedCount: Int { seen.count }
}
