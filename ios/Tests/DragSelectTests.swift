import Testing
import Foundation
@testable import Slab3

/// Scrub selection has one genuinely hard case — dragging back over rows you just
/// took — and one performance-critical one: turning a finger position into a row
/// without asking every row where it is. Both are pinned here so the gesture that
/// drives them is left with nothing to decide.
struct DragSelectTests {
    private let ids = (0..<10).map { _ in UUID() }

    // MARK: The span

    @Test func draggingDownTakesEverythingCrossed() {
        let result = DragSelectRange.apply(
            anchor: 2, current: 5, baseline: [ids[2]], selecting: true, rowIDs: ids)
        #expect(result == Set(ids[2...5]))
    }

    @Test func draggingUpFromTheAnchorAlsoTakesTheSpan() {
        let result = DragSelectRange.apply(
            anchor: 6, current: 3, baseline: [ids[6]], selecting: true, rowIDs: ids)
        #expect(result == Set(ids[3...6]))
    }

    /// THE case a row-by-row toggle gets wrong: overshoot, then come back. Every
    /// move recomputes the span from the anchor, so the rows left behind revert.
    @Test func comingBackDeselectsWhatTheOvershootTook() {
        let baseline: Set<UUID> = [ids[2]]
        _ = DragSelectRange.apply(anchor: 2, current: 8, baseline: baseline, selecting: true, rowIDs: ids)
        let afterReturn = DragSelectRange.apply(
            anchor: 2, current: 4, baseline: baseline, selecting: true, rowIDs: ids)
        #expect(afterReturn == Set(ids[2...4]), "rows 5 through 8 must not be stranded")
    }

    /// A scrub must not disturb what was already selected elsewhere in the list.
    @Test func selectionOutsideTheSpanSurvives() {
        let baseline: Set<UUID> = [ids[0], ids[9], ids[4]]
        let result = DragSelectRange.apply(
            anchor: 4, current: 6, baseline: baseline, selecting: true, rowIDs: ids)
        #expect(result.contains(ids[0]))
        #expect(result.contains(ids[9]))
        #expect(result.isSuperset(of: Set(ids[4...6])))
    }

    /// Long-press a row that is already selected and the drag clears instead —
    /// Photos paints in whichever direction the anchor went.
    @Test func aScrubCanDeselect() {
        let baseline = Set(ids)
        let result = DragSelectRange.apply(
            anchor: 3, current: 6, baseline: baseline, selecting: false, rowIDs: ids)
        #expect(result.isDisjoint(with: Set(ids[3...6])))
        #expect(result.contains(ids[0]), "and leaves the rest alone")
    }

    /// Dragging past the end keeps selecting to the end rather than stopping.
    @Test func theSpanClampsToTheList() {
        let result = DragSelectRange.apply(
            anchor: 7, current: 400, baseline: [], selecting: true, rowIDs: ids)
        #expect(result == Set(ids[7...9]))
    }

    @Test func anAnchorOffTheEndChangesNothing() {
        let baseline: Set<UUID> = [ids[1]]
        let result = DragSelectRange.apply(
            anchor: 99, current: 2, baseline: baseline, selecting: true, rowIDs: ids)
        #expect(result == baseline)
    }

    // MARK: Finger position to row

    @Test func aPointLandsOnItsRow() {
        // 88pt rows, 8pt gaps: row 0 spans 0..<88, row 1 starts at 96.
        #expect(DragSelectRange.index(at: 10, rowsTop: 0, rowHeight: 88, gap: 8, count: 10) == 0)
        #expect(DragSelectRange.index(at: 100, rowsTop: 0, rowHeight: 88, gap: 8, count: 10) == 1)
        #expect(DragSelectRange.index(at: 200, rowsTop: 0, rowHeight: 88, gap: 8, count: 10) == 2)
    }

    /// The rows do not start at the top of the scroll content — the summary block,
    /// filter pill and search sit above them.
    @Test func theRowsOffsetIsHonoured() {
        #expect(DragSelectRange.index(at: 310, rowsTop: 300, rowHeight: 88, gap: 8, count: 10) == 0)
        #expect(DragSelectRange.index(at: 400, rowsTop: 300, rowHeight: 88, gap: 8, count: 10) == 1)
    }

    @Test func aPointAboveTheFirstRowIsNoRow() {
        #expect(DragSelectRange.index(at: 250, rowsTop: 300, rowHeight: 88, gap: 8, count: 10) == nil)
    }

    @Test func aPointBelowTheLastRowClampsToIt() {
        #expect(DragSelectRange.index(at: 99_999, rowsTop: 0, rowHeight: 88, gap: 8, count: 10) == 9)
    }

    @Test func anEmptyListHasNoRows() {
        #expect(DragSelectRange.index(at: 40, rowsTop: 0, rowHeight: 88, gap: 8, count: 0) == nil)
        #expect(DragSelectRange.index(at: 40, rowsTop: 0, rowHeight: 0, gap: 8, count: 10) == nil)
    }
}

/// The session state around the pure math: which way the scrub paints, and the
/// promise that it only reports when the finger actually changes row.
@MainActor
struct DragSelectControllerTests {
    private let ids = (0..<6).map { _ in UUID() }

    @Test func aLongPressOnAnUnselectedRowStartsSelecting() {
        let controller = DragSelectController()
        let selection = controller.begin(at: 1, rowIDs: ids, selection: [])
        #expect(selection == [ids[1]])
        #expect(controller.isActive)
    }

    @Test func aLongPressOnASelectedRowStartsClearing() {
        let controller = DragSelectController()
        let selection = controller.begin(at: 1, rowIDs: ids, selection: Set(ids))
        #expect(!selection.contains(ids[1]))
        let dragged = controller.move(to: 3, rowIDs: ids)
        #expect(dragged?.isDisjoint(with: Set(ids[1...3])) == true)
    }

    /// Sixty reports a second for a finger that has not left the row would tick the
    /// haptic into mush and reassign the selection for nothing.
    @Test func stayingOnOneRowReportsNothing() {
        let controller = DragSelectController()
        _ = controller.begin(at: 2, rowIDs: ids, selection: [])
        #expect(controller.move(to: 2, rowIDs: ids) == nil)
        #expect(controller.move(to: 3, rowIDs: ids) != nil)
        #expect(controller.move(to: 3, rowIDs: ids) == nil)
    }

    @Test func endingClearsTheSession() {
        let controller = DragSelectController()
        _ = controller.begin(at: 0, rowIDs: ids, selection: [])
        controller.end()
        #expect(!controller.isActive)
        #expect(controller.move(to: 4, rowIDs: ids) == nil, "a finished scrub must not keep painting")
    }

    /// The Cards list disables scrolling while a scrub is active, so an anchor left
    /// standing is a list nobody can scroll (user report, 0.5). `endScrub` is now
    /// also called from paths that may fire when no scrub is running — leaving
    /// selection mode, and the screen disappearing — so ending must be safe to call
    /// at any time, including twice.
    @Test func endingIsSafeWhenNoScrubIsRunning() {
        let controller = DragSelectController()
        controller.end()
        #expect(!controller.isActive)

        _ = controller.begin(at: 2, rowIDs: ids, selection: [])
        controller.end()
        controller.end()
        #expect(!controller.isActive, "a second end must not revive the session")
    }
}
