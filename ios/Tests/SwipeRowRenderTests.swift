import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Slab3

/// Swipe is new territory for Caliper — the handoff has no swipe language at all —
/// so the two states it invents get rendered and looked at rather than reasoned
/// about, the way the comps panel does in DetailScreenRenderTests.
///
/// What to look for in the PNGs: the file action reads the real group name and
/// truncates rather than wrapping; Delete sits on the outside; and past the commit
/// point the delete action owns the whole row so the swipe's outcome is obvious
/// before the finger lifts.
///
/// Output: $TMPDIR/slabs-render/*.png
@MainActor
struct SwipeRowRenderTests {

    let store: ModelContainer = try! ModelContainer(
        for: Card.self, Folder.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    private func card(in context: ModelContext) -> Card {
        let c = Card(scan: CertScan(grader: .psa, certNumber: "96679812", raw: "96679812"))
        c.name = "Stephen Curry"
        c.set = "Panini Donruss Optic"
        c.year = 2022
        c.grade = "10"
        c.cardNumber = "10"
        c.cardLadderPriceCents = 8900
        c.cardLadderConfidence = 5
        context.insert(c)
        return c
    }

    /// The revealed state: both actions, with a real group name in the file button.
    @Test func rendersTheRevealedTray() throws {
        let url = try render(
            SwipeableCardRow.SwipeTray(
                fileTitle: "philcgc",
                pastCommit: false,
                expandedWidth: 357,
                onFile: {}, onDelete: {}
            )
            .frame(height: 96)
            .padding(Caliper.gutter)
            .background(Caliper.bg),
            named: "swipe-tray-open", height: 140
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A long group name must truncate inside its 84pt action rather than wrap or
    /// push Delete off the row.
    @Test func rendersALongGroupName() throws {
        let url = try render(
            SwipeableCardRow.SwipeTray(
                fileTitle: "Triumph 7/24 consignment",
                pastCommit: false,
                expandedWidth: 357,
                onFile: {}, onDelete: {}
            )
            .frame(height: 96)
            .padding(Caliper.gutter)
            .background(Caliper.bg),
            named: "swipe-tray-long-name", height: 140
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Past the commit point: delete owns the row and fills with danger.
    @Test func rendersThePastCommitState() throws {
        let url = try render(
            SwipeableCardRow.SwipeTray(
                fileTitle: "philcgc",
                pastCommit: true,
                expandedWidth: 357,
                onFile: {}, onDelete: {}
            )
            .frame(height: 96)
            .padding(Caliper.gutter)
            .background(Caliper.bg),
            named: "swipe-tray-commit", height: 140
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The row at rest must be indistinguishable from the row before any of this
    /// existed — the swipe is an accelerator, not a redesign.
    @Test func rendersTheRowAtRest() throws {
        let card = card(in: store.mainContext)
        var open: UUID?
        let url = try render(
            SwipeableCardRow(
                card: card,
                lens: .cl,
                fileTarget: nil,
                openRowID: .init(get: { open }, set: { open = $0 }),
                onTap: {}, onFile: {}, onDelete: {}
            )
            .padding(Caliper.gutter)
            .background(Caliper.bg),
            named: "swipe-row-rest", height: 140
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The undo window's only affordance, in the slot the selection bar uses.
    @Test func rendersTheUndoBar() throws {
        let url = try render(
            VStack(spacing: 0) {
                Spacer()
                UndoBar(label: "12 cards deleted", undo: {})
            }
            .background(Caliper.bg),
            named: "undo-bar", height: 120
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func render(_ view: some View, named name: String, height: CGFloat) throws -> URL {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 393, height: height) // iPhone 17 logical width
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slabs-render")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let image = renderer.uiImage, let data = image.pngData() else {
            throw RenderError.failed
        }
        try data.write(to: url)
        print("RENDERED \(url.path)")
        return url
    }

    enum RenderError: Error { case failed }
}
