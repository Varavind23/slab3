import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Slab3

/// Renders the Verified Max Buy Price panel to a PNG so its layout can be LOOKED
/// at, the way DetailScreenRenderTests does for the comps panel — three layout
/// bugs have shipped green in this project because nothing asserted on layout.
///
/// Both halves matter here for different reasons. COLLAPSED is what the person
/// being bought from sees, so what to check is that nothing in the frame reveals
/// the number is tunable. EXPANDED is a dense stack of sliders, chips and a typed
/// field inside a panel only 393pt wide, which is exactly the shape that overflowed
/// before.
///
/// Output: $TMPDIR/slabs-render/*.png — printed below and, by design, not asserted
/// on beyond existence.
@MainActor
struct MaxBuyPanelRenderTests {

    /// Stored, not per call: a container that deinits while SwiftUI still holds
    /// the view tears the model out from under it.
    let store: ModelContainer = try! ModelContainer(
        for: Card.self, Folder.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    /// Hostile on purpose: a four-figure price, a scattered low-population tape,
    /// and only two comps — the thin case, which is both the widest number and the
    /// hardest for the breakdown line to fit.
    private func card(in context: ModelContext, comps: [Int] = [128_050, 99_000]) -> Card {
        let c = Card(scan: CertScan(grader: .psa, certNumber: "96679812", raw: "96679812"))
        c.name = "Stephen Curry"
        c.title = "2022 Panini Donruss Optic Splash! #10 Stephen Curry Holo"
        c.grade = "10 GEM MINT"
        c.cardLadderPriceCents = 132_000
        c.cardLadderConfidence = 5
        c.courtyardPopulation = 23
        c.cardLadderSales = comps.enumerated().map { index, cents in
            RecentSale(priceCents: cents,
                       soldAt: Date(timeIntervalSince1970: 1_787_929_450 - Double(index) * 86_400),
                       platform: "eBay", listingType: "BestOffer",
                       title: nil, url: nil)
        }
        context.insert(c)
        return c
    }

    private func render(_ view: some View, named name: String, height: CGFloat = 1000) throws -> URL {
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

    /// What the seller sees. Look for: a label, a number, and "More" — and nothing
    /// else at all.
    @Test func rendersCollapsedWithNothingButTheNumber() throws {
        let card = card(in: store.mainContext)
        let url = try render(
            MaxBuyPanel(card: card, knobs: .constant(.standard))
                .padding(Caliper.gutter)
                .background(Caliper.bg),
            named: "maxbuy-collapsed", height: 140
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The working state. Look for: the window chips and the typed field sharing
    /// one baseline and one height, both sliders full width, and the breakdown
    /// line wrapping rather than running off the panel. Nothing here may be cyan —
    /// the detail screen spends its one cyan primary on "Refresh prices now".
    ///
    /// The typed field renders as a hatched placeholder: ImageRenderer cannot draw
    /// a UIKit-backed TextField. Its BORDER is drawn, so the geometry this test
    /// exists to check is still visible; only the glyphs are missing.
    @Test func rendersExpandedControls() throws {
        let card = card(in: store.mainContext)
        let url = try render(
            MaxBuyPanel(card: card, knobs: .constant(.standard), initiallyExpanded: true)
                .padding(Caliper.gutter)
                .background(Caliper.bg),
            named: "maxbuy-expanded", height: 460
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// No comps at this grade: an em dash and a reason, never a $0 and never a
    /// blank panel.
    ///
    /// The fixture must have NEITHER source's comps now. The panel no longer prices
    /// whichever source the toggle points at — it prefers Card Ladder and falls
    /// through to Courtyard — so giving the card CL comps and pointing at CY would
    /// render a price instead of the state this test exists to photograph.
    @Test func rendersTheNoCompsState() throws {
        let card = card(in: store.mainContext, comps: [])
        card.courtyardSales = nil
        let url = try render(
            MaxBuyPanel(card: card, knobs: .constant(.standard))
                .padding(Caliper.gutter)
                .background(Caliper.bg),
            named: "maxbuy-no-comps", height: 160
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // ── The rules the picture cannot assert ───────────────────────────────────

    /// The panel must not take the screen's one hero figure. `valueBlock` owns
    /// `.figure`; this uses the step below it.
    @Test func theFigureRegisterIsTheSecondaryOne() {
        #expect(Font.figureSmall != Font.figure)
    }

    /// A chip that is a button owes the design's 44pt target, per the rule
    /// ExportColumnsRenderTests pins for the export grid.
    @Test func windowChipsCarryATapTarget() {
        #expect(Chip.Size.tap.hitHeight >= Caliper.hitMin)
    }

    /// The gate is the whole reason this ships to one user. A wrong passcode, an
    /// empty one, or stray whitespace must not open it.
    @Test func theGateAcceptsOnlyTheRealPasscode() {
        #expect(TestingGate.accepts(TestingGate.passcode))
        #expect(TestingGate.accepts("  \(TestingGate.passcode) "), "typed on a phone keyboard")
        #expect(!TestingGate.accepts(""))
        #expect(!TestingGate.accepts("testing"))
        #expect(!TestingGate.accepts(TestingGate.passcode + "x"))
    }
}
