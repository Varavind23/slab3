import Testing
import CoreGraphics
@testable import Slab3

/// The feel of the row swipe is entirely in these numbers, and the gesture that
/// drives them cannot be tested without a finger — so the numbers are tested here
/// and the gesture is left with nothing to decide.
struct SwipeGeometryTests {
    private let rowWidth: CGFloat = 357 // iPhone 17 logical width less the gutters

    // MARK: Claiming the gesture

    /// The gate that stops a swipe from stealing a vertical scroll.
    @Test func onlyAHorizontalDragIsClaimed() {
        #expect(SwipeGeometry.isHorizontal(CGSize(width: -40, height: 4)))
        #expect(!SwipeGeometry.isHorizontal(CGSize(width: -4, height: -40)))
        #expect(!SwipeGeometry.isHorizontal(CGSize(width: -20, height: -20)),
                "a diagonal belongs to the scroll view, not the row")
    }

    // MARK: Where the row sits

    @Test func theRowTracksTheFingerOneForOne() {
        let offset = SwipeGeometry.offset(translation: -60, from: 0, rowWidth: rowWidth)
        #expect(offset == -60)
    }

    @Test func aRightwardDragDoesNothing() {
        #expect(SwipeGeometry.offset(translation: 80, from: 0, rowWidth: rowWidth) == 0)
        #expect(SwipeGeometry.offset(translation: 40, from: -20, rowWidth: rowWidth) == 0,
                "there is no right-hand action to reveal")
    }

    /// A partial swipe continues from where it settled, so a second drag on an
    /// already-open row doesn't jump back to the start.
    @Test func aDragContinuesFromTheOpenPosition() {
        let offset = SwipeGeometry.offset(
            translation: -30, from: -SwipeGeometry.trayWidth, rowWidth: rowWidth)
        #expect(offset == -SwipeGeometry.trayWidth - 30)
    }

    /// The row must be draggable across its WHOLE width — a full swipe is the
    /// delete gesture, so the tray width cannot be where it stops.
    @Test func theRowTravelsPastTheTrayToTheFullWidth() {
        let offset = SwipeGeometry.offset(translation: -(rowWidth - 10), from: 0, rowWidth: rowWidth)
        #expect(offset == -(rowWidth - 10))
        #expect(abs(offset) > SwipeGeometry.trayWidth)
    }

    @Test func pastTheRowWidthItResists() {
        let overshoot = SwipeGeometry.offset(translation: -(rowWidth + 120), from: 0, rowWidth: rowWidth)
        #expect(abs(overshoot) > rowWidth, "it still moves")
        #expect(abs(overshoot) < rowWidth + 120, "but not as far as the finger")
    }

    // MARK: Committing

    /// The commit point is measured against the TRAY, not as a fraction of the
    /// row: the red takes the whole back of the card once it has been dragged
    /// about half a File button past the File button. A row-relative fraction says
    /// the same thing on one screen width and something else on another.
    @Test func theCommitPointSitsJustPastTheFileAction() {
        let commit = SwipeGeometry.commitOffset(rowWidth: rowWidth)
        #expect(commit == -(SwipeGeometry.trayWidth + SwipeGeometry.actionWidth / 2))
        #expect(!SwipeGeometry.isPastCommit(-SwipeGeometry.trayWidth, rowWidth: rowWidth),
                "both actions merely revealed is not yet a delete")
        #expect(SwipeGeometry.isPastCommit(commit - 1, rowWidth: rowWidth))
    }

    /// On a narrow row the tray plus its overshoot could be almost the whole width,
    /// leaving the finger nowhere to commit from.
    @Test func theCommitPointStaysReachableOnANarrowRow() {
        let narrow: CGFloat = 200
        #expect(abs(SwipeGeometry.commitOffset(rowWidth: narrow)) <= narrow)
    }

    @Test func aPartialSwipeIsNotACommit() {
        #expect(!SwipeGeometry.isPastCommit(-100, rowWidth: rowWidth))
        #expect(SwipeGeometry.isPastCommit(-(rowWidth * 0.8), rowWidth: rowWidth))
    }

    @Test func releasingPastTheCommitPointDeletes() {
        let resolution = SwipeGeometry.resolve(
            offset: -(rowWidth * 0.9), predicted: -(rowWidth * 0.9), rowWidth: rowWidth)
        #expect(resolution == .delete)
    }

    /// A fast flick deletes even though the row never travelled that far — the
    /// gesture's projected end is what makes a swipe feel like a throw.
    @Test func aFastFlickDeletesOnItsProjectedEnd() {
        let resolution = SwipeGeometry.resolve(
            offset: -120, predicted: -(rowWidth * 1.4), rowWidth: rowWidth)
        #expect(resolution == .delete)
    }

    @Test func releasingPastHalfTheTraySnapsOpen() {
        let resolution = SwipeGeometry.resolve(
            offset: -(SwipeGeometry.trayWidth * 0.6), predicted: -(SwipeGeometry.trayWidth * 0.6),
            rowWidth: rowWidth)
        #expect(resolution == .open)
    }

    @Test func abandoningASwipeSnapsClosed() {
        let resolution = SwipeGeometry.resolve(offset: -20, predicted: -24, rowWidth: rowWidth)
        #expect(resolution == .closed)
    }

    // MARK: Constants the design depends on

    /// Both actions have to fit, and each has to be tappable once revealed.
    @Test func theTrayHoldsTwoTappableActions() {
        #expect(SwipeGeometry.trayWidth == SwipeGeometry.actionWidth * 2)
        #expect(SwipeGeometry.actionWidth >= Caliper.hitMin)
    }

    /// Zero would starve the scroll view's own pan gesture.
    @Test func theSwipeDoesNotClaimTheFirstPixel() {
        #expect(SwipeGeometry.minimumDragDistance > 0)
    }
}
