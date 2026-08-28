import Foundation

/// Suppresses the same cert for a short window after it is seen.
///
/// This exists because the rebuilt scanner reads barcodes off the raw video
/// stream, and Vision has no notion of a tracked item: a slab held in frame
/// re-detects on EVERY pass, ~12 times a second, so without it one slab would
/// buzz and flash a dozen times while you hold it.
///
/// What it does NOT do is prevent a duplicate ROW: `ScanScreen.add` checks the
/// stored cards unconditionally and refuses to insert a cert it already has. All
/// this decides is whether a sighting is worth REACTING to.
///
/// It replaces a `Set` that lived for the life of the scan session, which erred
/// the other way: a cert once seen could never be scanned again, so a deliberate
/// re-scan did nothing at all and never reached the "already in inventory" check
/// that would have explained why.
///
/// Two rules, because a timer alone gets one case wrong:
///
///   1. The same cert as the last one admitted is never admitted again. A slab
///      does not get deliberately rescanned twice in a row with nothing in
///      between — so a repeat is the camera re-reading what is still in your
///      hand, however long the gap. This is what makes intermittent detection
///      safe: a glare-obscured label that goes quiet for four seconds and comes
///      back is still the same slab, and a timer alone would treat it as new.
///
///   2. Any other cert seen recently is suppressed by a short trailing window,
///      which every sighting pushes back. This is what stops two slabs sitting
///      in frame together from taking turns re-triggering each other.
///
/// Rule 1 is why the window can be as short as it is: the long tail it used to
/// have to cover is handled by identity instead of by waiting.
struct RecentCertWindow {
    /// How long a DIFFERENT cert stays suppressed after being seen. Only has to
    /// cover slabs alternating in frame, since a repeat of the last one is
    /// blocked outright — so it is short on purpose.
    var suppression: TimeInterval = 1.5

    /// Entries older than this are dropped, so a long session doesn't grow the
    /// dictionary without bound.
    private let pruneAfter: TimeInterval = 60

    private var seen: [String: Date] = [:]

    /// The cert most recently admitted. Rule 1 above.
    private var lastAdmitted: String?

    init(suppression: TimeInterval = 1.5) {
        self.suppression = suppression
    }

    /// True if this cert should be accepted as a new scan right now.
    /// Always records the sighting, whether or not it was admitted.
    mutating func admit(_ key: String, now: Date = Date()) -> Bool {
        prune(now: now)
        let previous = seen[key]
        seen[key] = now

        // Rule 1: still the same slab. No timer involved — only a different cert
        // clears it, which is exactly the signal that you moved on.
        if key == lastAdmitted { return false }

        // Rule 2: a different cert, but one seen a moment ago.
        if let previous, now.timeIntervalSince(previous) < suppression { return false }

        lastAdmitted = key
        return true
    }

    /// Forget a cert immediately — used when its card is deleted, so the same
    /// slab can be re-scanned without waiting out the window.
    mutating func forget(_ key: String) {
        seen.removeValue(forKey: key)
        if lastAdmitted == key { lastAdmitted = nil }
    }

    mutating func removeAll() {
        seen.removeAll()
        lastAdmitted = nil
    }

    private mutating func prune(now: Date) {
        guard seen.count > 32 else { return }
        seen = seen.filter { now.timeIntervalSince($0.value) < pruneAfter }
    }

    var trackedCount: Int { seen.count }
}
