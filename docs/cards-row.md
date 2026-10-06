# Cards row — gestures, deletion, filing

Moved out of CLAUDE.md (2026-10-01) verbatim. Read before touching `SwipeableCardRow`, `SwipeGeometry` or `PendingDeletionStore`.

**The Cards row carries three gestures** (2026-09-16), kept apart on purpose: a tap
opens the card; a right-to-left swipe slides the CARD ITSELF, uncovering **Delete at
the outer edge** with *file into the group last used* inboard of it — dragged about
half a File button PAST the tray, Delete takes the whole back of the card and fills
red, and releasing there deletes (Gmail's promise — slide back to cancel); and a long
press opens **the system's own context menu** — Select / Remove from group / Delete.
The long press went back to iOS deliberately (2026-09-16): a hand-built 0.8s press
with a spring lift and a tuned haptic was built and then thrown away, because the
system menu brings Apple's zoom and haptic with it, and that pairing is what V4 had
and what the hand-built version never matched. Select turns selection mode on; there a tap toggles a
card and a drag always scrolls.

**Drag-to-select was REMOVED (2026-10-04, owner decision).** Selection mode used to
add a 0.4s-hold-then-drag "scrub" that took every row crossed, with edge auto-scroll.
Users scrolling a selected list kept tripping it: a thumb that rested for a moment
before moving painted every card in between instead of scrolling, and the
simultaneous SwiftUI gesture on each row competed with the scroll view (the same
iOS 18 trap as the swipe, below). The owner wasn't sure it was needed, so it went
rather than being re-tuned a third time. Do not bring a hold or drag back on the rows
in selection mode without a reason that survives that history; `All` in the header
covers the bulk case.

The row also takes `.frame(maxWidth: .infinity)` BEFORE its hit shape is computed.
Without it the tappable rect can stop short of the trailing price, meter and grade
chip, which is what made taps near the grade badge miss. The commit
point is measured against the tray (`SwipeGeometry.commitOffset`), never as a
fraction of the row: the tray is what the user is aiming at, and a fraction means
something different on every screen width.

**The row is NOT a `Button`, and must not become one again.** It was, and that one
fact caused both of the first version's bugs. `CaliperPressStyle` dims a pressed
button to 0.6, and the tray sat behind the row permanently — so ANY press made File
and Delete ghost through the card without a swipe. And a `Button` swallows the drag
it contains, so the card never followed the finger at all. The row is now a plain
view with `.onTapGesture`, and the tray is mounted ONLY while the card is off its
mark (held through the slide home, or the actions blink out from under a card still
moving over them). Rows lost their press dim along with the Button, which is no
loss: a tap pushes the detail screen, and that is its own feedback. Caliper has no swipe language at
all, so this extends the system deliberately, the way `Chip.Size.tap` did. The
long-press context menu that held Select / Remove from group / Delete is **gone**;
`SwipeableCardRow` carries those as `accessibilityActions`, which is the only route
VoiceOver has to them now. Swipe is masked off in selection mode
(`including: .subviews`) — the selection bar owns actions there.

Arbitration is the fragile part. **On iOS 18+ the swipe is a UIKit
`UIPanGestureRecognizer` (`HorizontalPan`, a `UIGestureRecognizerRepresentable`)
whose delegate refuses to BEGIN unless the first movement passes
`SwipeGeometry.isHorizontal` (horizontal beats vertical by 1.2×)** — a vertical
drag fails it at once and UIKit hands the touch to the ScrollView. It replaced a
SwiftUI `DragGesture` (0.7 user report): from iOS 18 SwiftUI gestures are real UIKit
recognisers, and that drag OWNED any touch that started on a card even though the
card never moved, so scrolling only worked from the header or mid-momentum. Do not
put a SwiftUI drag back on the row. iOS 17 keeps the old `DragGesture` path
(`minimumDistance: 8`, same horizontal gate). The UIKit pan reports velocity, not a
projected end, so `SwipeGeometry.projectedTravel` supplies the flick projection
(UIScrollView `.normal` deceleration). Every threshold and the rubber-band curve live in `SwipeGeometry`, tested, so
the gesture closure only reads a value and assigns a result.

**Deleting is deferred, never immediate.** `PendingDeletionStore` lives in
`MainShell` (rebuilt per screen, its timer would be cancelled by ARC and the delete
would silently never commit) and holds ONE batch — a new delete commits the previous
one, which is why there is never a question of which delete the Undo bar means.
Pending ids are filtered out of `CardsScreen.visible` AND `ExportScreen.scoped`, so a
card in its undo window is absent from inventory and from the CSV a buyer receives.
It commits on the 5s window, on another delete, on leaving the Cards tab, and on
`scenePhase == .background` — that last one is what stops a "deleted" card
reappearing after a relaunch. Both delete paths, swipe and the selection bar's bulk
Delete, go through it; the real delete is `CardDeletion.commit`, which re-reads the
store rather than closing over cards that may be stale seconds later.

`Folder.lastUsedAt` (additive-optional, per the SwiftData rule in CLAUDE.md) is what the
swipe's file action reads through `Folder.mostRecentlyUsed(in:)`. Set it beside
every `card.folder = group`, or the swipe starts offering a group nobody has touched
in weeks; nil everywhere means nothing has ever been filed and the action opens the
picker instead of inventing a destination.
