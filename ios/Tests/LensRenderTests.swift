import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Slab3

/// Renders everything the max-buy lens changes, so its layout can be LOOKED at —
/// three layout bugs have shipped green in this project because nothing asserted on
/// layout.
///
/// Two shapes here have overflowed before and are the reason this suite exists:
/// the row's line 2, which now carries BOTH source prices plus the metadata, and the
/// screen header, whose context label shares its line with a toggle that just grew a
/// third segment (`SalesPanel.swift` records the last time that header overflowed).
///
/// Output: $TMPDIR/slabs-render/*.png — printed below and, by design, not asserted
/// on beyond existence.
@MainActor
struct LensRenderTests {

    /// Stored, not per call: a container that deinits while SwiftUI still holds the
    /// view tears the model out from under it.
    let store: ModelContainer = try! ModelContainer(
        for: Card.self, Folder.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    private let day0 = Date(timeIntervalSince1970: 1_787_929_450)

    /// Hostile on purpose: a long title, four-figure prices on both sources, and a
    /// full meta line — the widest each part of the row gets.
    private func card(in context: ModelContext, comps: [Int]? = [128_050, 99_000]) -> Card {
        let c = Card(scan: CertScan(grader: .psa, certNumber: "96679812", raw: "96679812"))
        c.name = "Stephen Curry"
        c.title = "2022 Panini Donruss Optic Splash! #10 Stephen Curry Holo"
        c.set = "Panini Donruss Optic"
        c.year = 2022
        c.grade = "10"   // normalized by GradeText at ingest; the row never sees the long form
        c.cardLadderPriceCents = 132_000
        c.cardLadderConfidence = 5
        c.courtyardPriceCents = 124_500
        c.courtyardConfidence = 2
        c.courtyardPopulation = 23
        if let comps {
            c.cardLadderSales = comps.enumerated().map { index, cents in
                RecentSale(priceCents: cents,
                           soldAt: day0.addingTimeInterval(-Double(index) * 86_400),
                           platform: "eBay", listingType: "BestOffer", title: nil, url: nil)
            }
        }
        context.insert(c)
        return c
    }

    private func render(_ view: some View, named name: String, height: CGFloat = 400) throws -> URL {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 393, height: height) // iPhone 17 logical width
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slabs-render")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let image = renderer.uiImage, let data = image.pngData() else { throw RenderError.failed }
        try data.write(to: url)
        print("RENDERED \(url.path)")
        return url
    }

    /// The row and the toast price off the SAVED baseline, the hero off the knobs it
    /// is handed. Pinning both to `.standard` is what lets the row and the hero agree
    /// in the pictures — unpinned, the row rendered whatever margin the last
    /// `MaxBuyValueTests` case left behind ($1,082.25 against the hero's $934.81).
    /// `ImageRenderer` draws synchronously inside `render`, so the pin covers it.
    private func renderAtBaseline(_ view: some View, named name: String,
                                  height: CGFloat = 400) throws -> URL {
        try MaxBuyDefaults.withPinned(.standard) {
            try render(view, named: name, height: height)
        }
    }

    enum RenderError: Error { case failed }

    // ── The row ───────────────────────────────────────────────────────────────

    /// The lens row stacked on a CL row. What to look at: line 1 reads `MAX BUY` in
    /// white rather than a source hue; line 2 carries BOTH prices and the metadata
    /// truncates rather than pushing anything out; and the two rows' RIGHT EDGES
    /// land on the same pixel, because the blank meter slot keeps its 43pt.
    @Test func rendersTheRowUnderTheMaxBuyLens() throws {
        let card = card(in: store.mainContext)
        let url = try renderAtBaseline(
            VStack(spacing: Caliper.rowGap) {
                CardRow(card: card, lens: .maxBuy)
                CardRow(card: card, lens: .cl)
            }
            .padding(Caliper.gutter)
            .background(Caliper.bg),
            named: "lens-row", height: 260
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The two totals under MAX. What to look at: the summary's headline reads
    /// MAX BUY TOTAL with NO payout half, and its count says "with max buy"; the
    /// bar's figure carries its MAX BUY basis label, and a short count reads
    /// "12 selected · 9 priced" without crowding the figure off its line.
    @Test func rendersTheTotalsUnderTheLens() throws {
        let url = try render(
            VStack(spacing: Caliper.space6) {
                SummaryBlock(totalCents: 421_050, payoutCents: nil, matched: 9, of: 12, maxBuy: true)
                SummaryBlock(totalCents: 612_000, payoutCents: 489_600, matched: 12, of: 12)
                Spacer(minLength: 0)
                SelectionBar(count: 12, totalCents: 421_050, counted: 9, basis: PriceLens.maxBuy.rowLabel,
                             group: {}, remove: {}, export: {}, delete: {})
                SelectionBar(count: 3, totalCents: 90_000, counted: 3,
                             group: {}, remove: {}, export: {}, delete: {})
            }
            .padding(.vertical, Caliper.gutter)
            .background(Caliper.bg),
            named: "lens-totals", height: 720
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A card no source has comps for. An em dash, never `$0` and never a blank —
    /// and the row keeps its shape.
    @Test func rendersTheRowWithNoComps() throws {
        let card = card(in: store.mainContext, comps: nil)
        let url = try renderAtBaseline(
            CardRow(card: card, lens: .maxBuy)
                .padding(Caliper.gutter)
                .background(Caliper.bg),
            named: "lens-row-no-comps", height: 140
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // ── The header ────────────────────────────────────────────────────────────

    /// Locked above unlocked, with the longest context label the Cards tab produces.
    /// What to look at: the third segment does not push the label into the toggle,
    /// and the locked header is unchanged from what shipped.
    @Test func rendersTheHeaderWithTwoAndThreeSegments() throws {
        let url = try render(
            VStack(spacing: 0) {
                ScreenHeader(context: "255 cards", title: "Inventory",
                             lens: .constant(.cl), lenses: PriceLens.sources)
                ScreenHeader(context: "3 of 255 selected", title: "Select cards",
                             contextTint: Caliper.cyan,
                             lens: .constant(.maxBuy),
                             lenses: PriceLens.allCases)
            }
            .background(Caliper.bg),
            named: "lens-header", height: 260
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // ── The hero ──────────────────────────────────────────────────────────────

    /// The detail screen's hero under both lenses. What to look at: "Max buy" takes
    /// the same `.figure` register the source value does, carries NO confidence
    /// meter, and still shows a last-sold beneath it.
    @Test func rendersTheDetailHeroUnderTheLens() throws {
        let card = card(in: store.mainContext)
        let url = try render(
            HStack(alignment: .top, spacing: Caliper.space6) {
                ValueBlock(card: card, lens: .maxBuy, knobs: .standard)
                ValueBlock(card: card, lens: .cl)
            }
            .padding(Caliper.gutter)
            .background(Caliper.bg),
            named: "lens-hero", height: 260
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// The hero must move with the panel's sliders, or one screen shows two
    /// differently-tuned figures under the same label.
    @Test func theHeroFollowsTheKnobsItIsGiven() {
        let card = card(in: store.mainContext)
        let plain = MaxBuyValue.answer(for: card, knobs: .init(windowN: 5, skew: 0, margin: 0)).cents
        let cut = MaxBuyValue.answer(for: card, knobs: .init(windowN: 5, skew: 0, margin: 0.5)).cents
        #expect(plain != nil && cut != nil)
        #expect(cut! < plain!)
    }

    // ── The scan toast ────────────────────────────────────────────────────────

    /// Under the lens the toast carries the figure; under a source lens it is
    /// exactly what shipped. Both in one frame so the difference is the only thing
    /// to look at.
    @Test func rendersTheScanToastUnderTheLens() throws {
        let card = card(in: store.mainContext)
        let url = try renderAtBaseline(
            VStack(spacing: Caliper.rowGap) {
                ScanToastView(toast: .captured(card: card), lens: .maxBuy)
                ScanToastView(toast: .captured(card: card), lens: .cl)
            }
            .padding(Caliper.gutter)
            .background(Caliper.bg),
            named: "lens-scan-toast", height: 300
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // ── The rules the picture cannot assert ───────────────────────────────────

    /// The blank slot must be exactly the meter's width, or the row's right edge
    /// moves when the toggle flips — the one geometric promise the toggle makes.
    @Test func theBlankMeterSlotKeepsTheMetersWidth() {
        #expect(ConfidenceMeter.totalWidth == 43)
    }
}
