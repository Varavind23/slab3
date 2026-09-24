import CoreGraphics

/// The arithmetic behind the row swipe — every threshold and curve in one place,
/// with no SwiftUI in sight.
///
/// It is separate from the gesture for two reasons. The feel of a swipe lives
/// entirely in these numbers, so they belong somewhere a person can find and tune
/// them rather than buried in a `.onChanged` closure. And the gesture itself cannot
/// be unit-tested — a finger is required — while all of this can be, which is what
/// keeps the untestable part down to "read the value, call one function, assign the
/// result".
///
/// Sign convention: offsets are NEGATIVE, because the row only travels leftward.
/// There is no right-hand action, so a rightward drag is clamped to rest.
enum SwipeGeometry {

    /// One action in the tray. Wider than `Caliper.hitMin` because these carry a
    /// word, not a glyph.
    static let actionWidth: CGFloat = 84

    /// File + Delete. What a partial swipe settles open at.
    static var trayWidth: CGFloat { actionWidth * 2 }

    /// How far the finger travels before the row moves at all.
    ///
    /// Not zero (as `CaliperSlider` uses) on purpose: a drag that claims the
    /// gesture on the first pixel starves the enclosing ScrollView's pan of its
    /// chance to begin, and vertical scrolling over a row goes sticky. Eight points
    /// is under a finger's natural jitter and still leaves the tap to the Button.
    static let minimumDragDistance: CGFloat = 8

    /// How much horizontal must beat vertical before we treat a drag as a swipe.
    static let horizontalBias: CGFloat = 1.2

    /// How far PAST the tray the card must travel before the swipe becomes a
    /// delete: half an action width beyond both actions.
    ///
    /// Measured against the tray rather than as a fraction of the row, because the
    /// tray is what the user is looking at — "the red takes the whole back of the
    /// card once you have slid it about half a File button past the File button".
    /// A row-relative fraction says the same thing on one screen width and
    /// something else on another.
    static let commitOvershoot: CGFloat = actionWidth / 2

    /// Where the swipe turns into a delete. Capped so it stays reachable on a
    /// narrow row, where the tray plus its overshoot could otherwise be most of
    /// the width the finger has to work with.
    static func commitOffset(rowWidth: CGFloat) -> CGFloat {
        -min(trayWidth + commitOvershoot, max(rowWidth * 0.9, trayWidth))
    }

    /// Resistance once the row has travelled its whole width. UIScrollView's own
    /// coefficient — the same feel as pulling past the end of a list.
    static let rubberBand: CGFloat = 0.55

    /// What a release does.
    enum Resolution: Equatable {
        case closed
        case open
        case delete
    }

    /// Is this drag horizontal enough to claim? SwiftUI has no direction-locked
    /// DragGesture, so this is the gate that keeps a swipe from stealing a scroll.
    static func isHorizontal(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) * horizontalBias
    }

    /// Where the row sits for a given finger travel.
    ///
    /// Three regions: it tracks the finger one-for-one out to the full row width
    /// (the whole width, not just the tray — a full swipe has to be reachable),
    /// resists beyond that, and clamps at rest going the other way.
    static func offset(translation: CGFloat, from committed: CGFloat, rowWidth: CGFloat) -> CGFloat {
        let raw = committed + translation
        if raw >= 0 { return 0 }
        let travel = -raw
        guard travel > rowWidth, rowWidth > 0 else { return raw }
        return -(rowWidth + resisted(travel - rowWidth, over: rowWidth))
    }

    /// Past the point where releasing deletes — where the delete action takes over
    /// the whole back of the card and the haptic fires.
    static func isPastCommit(_ offset: CGFloat, rowWidth: CGFloat) -> Bool {
        offset <= commitOffset(rowWidth: rowWidth)
    }

    /// What to do when the finger lifts. `predicted` is the gesture's projected
    /// end translation, which is what makes a fast flick commit even though the row
    /// never actually travelled that far.
    static func resolve(offset: CGFloat, predicted: CGFloat, rowWidth: CGFloat) -> Resolution {
        if isPastCommit(offset, rowWidth: rowWidth) || isPastCommit(predicted, rowWidth: rowWidth) {
            return .delete
        }
        return offset <= -(trayWidth / 2) ? .open : .closed
    }

    /// How much further a release at `velocity` (pt/s) would carry the card — what
    /// SwiftUI's `predictedEndTranslation` gave the old DragGesture, recomputed for
    /// the UIKit pan, which reports only velocity. UIScrollView's `.normal`
    /// deceleration (0.998 per ms) is the standard projection, and it is what makes
    /// a fast flick commit a delete the way it did before.
    static func projectedTravel(velocity: CGFloat) -> CGFloat {
        let rate: CGFloat = 0.998
        return (velocity / 1000) * rate / (1 - rate)
    }

    /// What a release does, given whether this drag was ever CLAIMED as a swipe.
    ///
    /// nil = not a swipe at all: leave the row exactly as it is. This is what keeps
    /// a scroll from deleting a card (0.7). `onEnded` fires for a vertical drag too,
    /// and `resolve` reads the projected end translation — so a fast scroll flick
    /// with any leftward lean projected past the commit point and deleted the row
    /// under the finger, without the card ever having moved. Only a drag that
    /// passed `isHorizontal` may resolve.
    static func release(offset: CGFloat, predicted: CGFloat, rowWidth: CGFloat, claimed: Bool) -> Resolution? {
        guard claimed else { return nil }
        return resolve(offset: offset, predicted: predicted, rowWidth: rowWidth)
    }

    /// UIScrollView's resistance curve: the further past the edge, the less each
    /// point of finger travel moves the row.
    private static func resisted(_ excess: CGFloat, over dimension: CGFloat) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return (1 - (1 / (excess * rubberBand / dimension + 1))) * dimension
    }
}
