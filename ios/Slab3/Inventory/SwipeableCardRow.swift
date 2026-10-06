import SwiftUI
import UIKit

/// A card row you can swipe left: file it into the group you last used, or delete
/// it. Carry the swipe far enough and the delete takes the whole back of the card,
/// and releasing there deletes.
///
/// WHY THIS IS HAND-BUILT. `.swipeActions` is a `List` API and this app has no
/// `List` anywhere — the inventory is a `ScrollView` + `LazyVStack` so that the
/// summary block, filter pill and search share its scroll, and so Caliper's square
/// hairline rows survive contact with the system's own row styling.
///
/// TWO THINGS THE FIRST VERSION GOT WRONG, both caused by the row being a `Button`
/// (2026-09-16):
///
///   * `CaliperPressStyle` dims a pressed button to 0.6, and the tray sat behind
///     the row permanently — so ANY press made File and Delete ghost through the
///     card without a swipe having happened at all. The tray is now mounted only
///     while the card is actually moving, and torn down after it settles back.
///   * A `Button` tends to swallow the drag it contains, so the card never
///     followed the finger. The row is now a plain view with its own tap gesture,
///     which leaves the drag free to move it. The cost is the press dim on a row,
///     which is no loss: a tap pushes the detail screen, and that is its own
///     feedback.
///
/// Swipe is deliberately dead in selection mode. The selection bar owns actions
/// there, and a horizontal drag across a half-selected list is ambiguous about
/// whether it means this card or all of them.
struct SwipeableCardRow: View {
    let card: Card
    let lens: PriceLens
    var selectable: Bool = false
    var selected: Bool = false
    /// Price paid, already gated on the Settings toggle (`AppState.paidCents`).
    var paidCents: Int? = nil
    /// Where a file action would put this card. `nil` = nothing has ever been
    /// filed, so the action opens the picker rather than inventing a destination.
    let fileTarget: Folder?
    /// Whose tray is open, app-wide. One at a time.
    @Binding var openRowID: UUID?
    let onTap: () -> Void
    let onFile: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    /// Where the card rests between drags, so a second drag on an open row
    /// continues rather than jumping back to the start.
    @State private var restingOffset: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    /// Mounted while the card is away from rest AND while it slides home, so the
    /// actions do not blink out from under a card that is still moving.
    @State private var trayMounted = false
    @State private var haptickedAtCommit = false
    /// Whether THIS drag ever passed the horizontal gate. A drag that never did is a
    /// scroll, and its release must not resolve — see `SwipeGeometry.release`.
    @State private var claimed = false
    /// Where the current drag began — how a new drag is told from the last one.
    @State private var dragStart: CGPoint?
    // Held and prepared, like the scanner's: built per gesture, the first buzz
    // arrives late enough to feel disconnected from the finger.
    @State private var impact = UIImpactFeedbackGenerator(style: .rigid)

    private var isOpen: Bool { restingOffset != 0 }
    private var pastCommit: Bool { SwipeGeometry.isPastCommit(offset, rowWidth: rowWidth) }

    /// The tray shows the GROUP NAME, not "File in <name>". In 84 points the verb
    /// eats the half of the label that carries the information — a render of
    /// "Weekend show 7/24" came out as "FILE IN WEEK…", which names no group at all. The
    /// folder glyph above it is the verb.
    private var fileTitle: String { fileTarget?.name ?? "File…" }

    /// VoiceOver has room for the whole sentence, and needs it: there is no glyph
    /// to carry the verb when the action is read aloud.
    private var fileActionLabel: String {
        fileTarget.map { "File in \($0.name)" } ?? "File in a group"
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Only while the card is off its mark. At rest there is nothing behind
            // the row at all, which is what stops the actions showing through it.
            if trayMounted { tray }

            CardRow(card: card, lens: lens, selectable: selectable, selected: selected, paidCents: paidCents)
                // Full width BEFORE the hit shape is taken. The row's own trailing
                // content — price, meter, grade chip — sits against the right edge,
                // and without this the tappable rect could stop short of it, which
                // is what made taps near the grade badge miss (2026-09-16).
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { tapped() }
                .offset(x: offset)
                // The ScrollView must take vertical drags and this horizontal
                // ones. Disabled in selection mode, leaving the row's tap alone.
                .modifier(SwipeGestureAttachment(row: self))
        }
        .background(widthReader)
        .clipped()
        .onAppear { impact.prepare() }
        .onChange(of: openRowID) { _, id in
            if id != card.localId, isOpen { close() }
        }
        // A row that scrolls away mid-swipe must not come back still open.
        .onDisappear { if isOpen { close(animated: false) } }
        .onChange(of: selectable) { _, nowSelecting in
            if nowSelecting, isOpen { close(animated: false) }
        }
        // A swipe is invisible to VoiceOver, and the long-press menu that used to
        // carry these actions is gone — so these are the only route left.
        .accessibilityActions {
            Button(fileActionLabel) { onFile() }
            Button("Delete") { onDelete() }
        }
    }

    // MARK: Tray

    private var tray: some View {
        SwipeTray(
            fileTitle: fileTitle,
            pastCommit: pastCommit,
            expandedWidth: max(rowWidth, SwipeGeometry.actionWidth),
            onFile: {
                close()
                onFile()
            },
            onDelete: commitDelete
        )
    }

    /// Behind the card: Delete on the OUTSIDE, uncovered first, with File inboard
    /// of it — Apple Mail's arrangement. Delete stays last and is the only red
    /// thing, the same rule the selection bar follows.
    ///
    /// Split out from the row because the row's offset is gesture state and cannot
    /// be posed — this can be rendered at either of its states and looked at, which
    /// is the whole reason the render-test pattern exists in this suite.
    struct SwipeTray: View {
        let fileTitle: String
        /// Once the card has been dragged half a File button past the File button,
        /// the delete takes the entire back of the card and fills with danger: the
        /// swipe has BECOME a delete, and releasing here commits it.
        let pastCommit: Bool
        let expandedWidth: CGFloat
        let onFile: () -> Void
        let onDelete: () -> Void

        var body: some View {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if !pastCommit {
                    button(title: fileTitle, icon: "folder",
                           ink: Caliper.textPrimary, fill: Caliper.surface2, run: onFile)
                        .frame(width: SwipeGeometry.actionWidth)
                }
                button(title: "Delete", icon: "trash",
                       ink: pastCommit ? Caliper.bg : Caliper.danger,
                       fill: pastCommit ? Caliper.danger : Caliper.surface2,
                       run: onDelete)
                    .frame(width: pastCommit ? expandedWidth : SwipeGeometry.actionWidth)
            }
            // A discrete state change, unlike the offset — safe to animate, where
            // animating the offset would make the card lag the finger.
            .animation(Caliper.easeOut, value: pastCommit)
        }

        private func button(
            title: String, icon: String, ink: Color, fill: Color, run: @escaping () -> Void
        ) -> some View {
            Button(action: run) {
                VStack(spacing: Caliper.space2) {
                    Image(systemName: icon).font(.system(size: 15))
                    Text(title)
                        .caliperLabel(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, Caliper.space2)
                }
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(fill)
                .contentShape(Rectangle())
            }
            .buttonStyle(CaliperPressStyle())
        }
    }

    /// Measures without affecting layout — a GeometryReader in the hierarchy proper
    /// would take all the space it was offered instead of sizing to the row.
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { rowWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in rowWidth = width }
        }
    }

    // MARK: Gesture

    /// iOS 18+: a UIKit pan that only BEGINS on a sideways first move (0.7 fix).
    ///
    /// WHY NOT A SwiftUI DragGesture any more: from iOS 18, SwiftUI gestures are
    /// real UIKit recognisers, and a DragGesture on a row inside a ScrollView takes
    /// the touch before the ScrollView's own pan can. The row did not MOVE on a
    /// vertical drag (the horizontal gate below saw to that) but it still OWNED the
    /// touch — so a scroll that started on a card went nowhere, while one started on
    /// the summary block, or caught mid-momentum, worked (user report, 0.7). A
    /// `UIPanGestureRecognizer` whose delegate refuses to begin unless the first
    /// movement is horizontal fails at once on a vertical drag, and UIKit hands the
    /// touch straight to the ScrollView. SwiftUI has no direction-locked drag; this
    /// is the direction lock.
    @available(iOS 18.0, *)
    fileprivate var horizontalPan: HorizontalPan {
        HorizontalPan(
            isEnabled: !selectable,
            changed: { swipeMoved(translationX: $0) },
            ended: { translationX, velocityX in
                swipeReleased(
                    predictedX: translationX + SwipeGeometry.projectedTravel(velocity: velocityX),
                    claimed: true)
            },
            cancelled: { swipeCancelled() }
        )
    }

    /// iOS 17 keeps the SwiftUI drag. It predates the UIKit-backed gesture system,
    /// where the ScrollView still gets a fair first move.
    fileprivate var swipe: some Gesture {
        DragGesture(minimumDistance: SwipeGeometry.minimumDragDistance, coordinateSpace: .local)
            .onChanged { value in
                // A new touch starts unclaimed. Keyed on the start point rather than
                // cleared in `onEnded`, because a CANCELLED drag (the ScrollView
                // taking over, the row recycled) never reaches `onEnded` and would
                // otherwise hand its claim to the next drag — a scroll.
                if value.startLocation != dragStart {
                    dragStart = value.startLocation
                    claimed = false
                }
                // Until horizontal intent is unambiguous the card does not move.
                // Once claimed, it keeps following even if the finger drifts
                // vertical — un-claiming mid-swipe would strand it off its mark.
                guard claimed || SwipeGeometry.isHorizontal(value.translation) else { return }
                claimed = true
                swipeMoved(translationX: value.translation.width)
            }
            .onEnded { value in
                // Ended by a DIFFERENT touch than the one that claimed? Then it was
                // never claimed at all.
                let wasClaimed = claimed && value.startLocation == dragStart
                claimed = false
                dragStart = nil
                swipeReleased(
                    predictedX: value.predictedEndTranslation.width, claimed: wasClaimed)
            }
    }

    // Both gestures feed these, so the swipe behaves the same on every iOS.

    private func swipeMoved(translationX: CGFloat) {
        trayMounted = true
        openRowID = card.localId
        offset = SwipeGeometry.offset(translation: translationX, from: restingOffset, rowWidth: rowWidth)

        let past = SwipeGeometry.isPastCommit(offset, rowWidth: rowWidth)
        if past, !haptickedAtCommit {
            impact.impactOccurred()
            haptickedAtCommit = true
        } else if !past {
            haptickedAtCommit = false
        }
    }

    private func swipeReleased(predictedX: CGFloat, claimed: Bool) {
        haptickedAtCommit = false
        guard let resolution = SwipeGeometry.release(
            offset: offset,
            predicted: restingOffset + predictedX,
            rowWidth: rowWidth,
            claimed: claimed
        ) else { return }
        settle(resolution)
    }

    /// The system took the touch mid-swipe (a call, the row recycled). Settle by
    /// where the card IS — never by a projection, so a cancel can never delete.
    private func swipeCancelled() {
        haptickedAtCommit = false
        let resolution = SwipeGeometry.resolve(offset: offset, predicted: offset, rowWidth: rowWidth)
        settle(resolution == .delete ? .open : resolution)
    }

    private func settle(_ resolution: SwipeGeometry.Resolution) {
        switch resolution {
        case .delete:
            commitDelete()
        case .open:
            withAnimation(Caliper.easeOut) { offset = -SwipeGeometry.trayWidth }
            restingOffset = -SwipeGeometry.trayWidth
            openRowID = card.localId
        case .closed:
            close()
        }
    }

    // MARK: Actions

    /// A tap on an open card closes it rather than opening the card — the same rule
    /// every list with a revealed action follows.
    private func tapped() {
        if isOpen { close() } else { onTap() }
    }

    private func close(animated: Bool = true) {
        restingOffset = 0
        if openRowID == card.localId { openRowID = nil }
        guard animated else {
            offset = 0
            trayMounted = false
            return
        }
        withAnimation(Caliper.easeOut) { offset = 0 }
        // Held until the card has finished sliding home, or the actions would blink
        // out from under a card that is still moving over them.
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if offset == 0 { trayMounted = false }
        }
    }

    /// The card leaves the list now — `onDelete` puts it in the undo window, so the
    /// disappearance IS the animation and this view is on its way out. State is
    /// reset anyway, because an undo brings the same row back and it must not
    /// return still swiped open.
    private func commitDelete() {
        offset = 0
        restingOffset = 0
        trayMounted = false
        if openRowID == card.localId { openRowID = nil }
        onDelete()
    }
}

/// Picks the swipe recogniser for the running OS. A modifier because
/// `if #available` cannot sit inside a view-modifier chain.
private struct SwipeGestureAttachment: ViewModifier {
    let row: SwipeableCardRow

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(row.horizontalPan)
        } else {
            content.gesture(row.swipe, including: row.selectable ? .subviews : .all)
        }
    }
}

/// A pan that begins only when its first movement is horizontal — the direction
/// lock SwiftUI's DragGesture lacks. See `SwipeableCardRow.horizontalPan`.
@available(iOS 18.0, *)
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    /// Horizontal travel since the pan began.
    var changed: (CGFloat) -> Void
    /// Travel and horizontal velocity (pt/s) at release.
    var ended: (CGFloat, CGFloat) -> Void
    var cancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let view = recognizer.view
        switch recognizer.state {
        case .began, .changed:
            changed(recognizer.translation(in: view).x)
        case .ended:
            ended(recognizer.translation(in: view).x, recognizer.velocity(in: view).x)
        case .cancelled, .failed:
            cancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The whole fix: refuse to begin unless the drag starts sideways, so a
        /// vertical drag fails here immediately and the ScrollView scrolls.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return SwipeGeometry.isHorizontal(CGSize(width: v.x, height: v.y))
        }
    }
}
