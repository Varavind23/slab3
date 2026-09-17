import Foundation
import Observation
import UIKit

/// Photos-style scrub selection: long-press a row to take it, then keep dragging to
/// take everything the finger crosses.
///
/// The arithmetic is here and pure; the gesture that feeds it is in `CardsScreen`,
/// where it cannot be tested because a finger is required. Everything that decides
/// WHAT gets selected lives in `DragSelectRange` so that the untestable part is
/// reduced to "read the location, call one function, assign the result".
enum DragSelectRange {

    /// The selection after the finger has travelled from `anchor` to `current`.
    ///
    /// Recomputed from the anchor on EVERY move against the selection as it stood
    /// when the drag began — never toggled row by row as they are crossed. That is
    /// precisely what makes dragging back up deselect: the covered span shrinks and
    /// the rows that fall outside it return to whatever they were before, so an
    /// overshoot and return leaves nothing stranded. Toggling incrementally would
    /// need direction tracking and would still get that case wrong.
    static func apply(
        anchor: Int,
        current: Int,
        baseline: Set<UUID>,
        selecting: Bool,
        rowIDs: [UUID]
    ) -> Set<UUID> {
        guard rowIDs.indices.contains(anchor) else { return baseline }
        let clamped = min(max(current, 0), rowIDs.count - 1)
        let span = min(anchor, clamped)...max(anchor, clamped)
        var result = baseline
        for id in rowIDs[span] {
            if selecting { result.insert(id) } else { result.remove(id) }
        }
        return result
    }

    /// Which row a point falls on.
    ///
    /// Rows are a uniform height — `CardRow` is three single-line rows beside a
    /// fixed 46×64 thumbnail, in fixed-size mono faces that do not scale with
    /// Dynamic Type — so a division answers this in constant time at any inventory
    /// size. The alternative, every row publishing its frame through a
    /// PreferenceKey, re-publishes the whole list on every scroll tick, which is
    /// the one shape guaranteed to stutter on a 200-slab stack.
    ///
    /// Returns nil above the first row; clamps below the last, so dragging past the
    /// end keeps selecting to the end instead of stopping.
    static func index(
        at y: CGFloat,
        rowsTop: CGFloat,
        rowHeight: CGFloat,
        gap: CGFloat,
        count: Int
    ) -> Int? {
        guard count > 0, rowHeight > 0 else { return nil }
        let offset = y - rowsTop
        guard offset >= 0 else { return nil }
        return min(Int(offset / (rowHeight + gap)), count - 1)
    }
}

/// The live state of one scrub: where it started, what was selected before it, and
/// which way it is painting.
@MainActor
@Observable
final class DragSelectController {
    private(set) var anchor: Int?
    private var baseline: Set<UUID> = []
    /// Photos paints in the direction the ANCHOR went: long-press an unselected row
    /// and the drag selects; long-press a selected one and the drag clears.
    private var selecting = true
    private var lastIndex: Int?

    @ObservationIgnored private let tick = UISelectionFeedbackGenerator()

    var isActive: Bool { anchor != nil }

    /// The long press landed. Returns the selection with the anchor row toggled.
    func begin(at index: Int, rowIDs: [UUID], selection: Set<UUID>) -> Set<UUID> {
        guard rowIDs.indices.contains(index) else { return selection }
        let id = rowIDs[index]
        selecting = !selection.contains(id)
        var next = selection
        if selecting { next.insert(id) } else { next.remove(id) }
        anchor = index
        // The baseline carries the anchor's NEW state, so shrinking the span back
        // to the anchor alone leaves it as the long press left it.
        baseline = next
        lastIndex = index
        tick.prepare()
        return next
    }

    /// The finger moved. Returns nil when it has not yet crossed into another row,
    /// so the caller neither reassigns the selection nor ticks the haptic sixty
    /// times a second.
    func move(to index: Int, rowIDs: [UUID]) -> Set<UUID>? {
        guard let anchor, !rowIDs.isEmpty else { return nil }
        let clamped = min(max(index, 0), rowIDs.count - 1)
        guard clamped != lastIndex else { return nil }
        lastIndex = clamped
        tick.selectionChanged()
        return DragSelectRange.apply(
            anchor: anchor, current: clamped,
            baseline: baseline, selecting: selecting, rowIDs: rowIDs
        )
    }

    /// When the last scrub finished. A tap arriving immediately after a long press
    /// is the same touch being reported twice — the row checks this and ignores it,
    /// rather than toggling off the selection the press has just made.
    private(set) var endedAt: Date?

    func end() {
        anchor = nil
        lastIndex = nil
        baseline = []
        endedAt = Date()
    }
}
