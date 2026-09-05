import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Slab3

/// Renders the card detail screen to a PNG so its layout can actually be LOOKED
/// at, rather than reasoned about.
///
/// Exists because the comps panel shipped with three overflow bugs that no unit
/// test could have caught — the CL|CY toggle pushed past the panel edge, sale
/// dates ran off the right, and content sat on the border — while every
/// assertion in the suite stayed green. Layout is a visual property; this gives
/// it a visual check that needs no account, no device and no network.
///
/// Output: $TMPDIR/slabs-render/*.png (printed below, and by design not asserted
/// on — it is a developer's eye that reads these, not an equality check).
@MainActor
struct DetailScreenRenderTests {

    /// Stored, not created per call: a container that deinits while SwiftUI still
    /// holds the view tears the model out from under it ("this model instance was
    /// destroyed by calling ModelContext.reset"). Swift Testing makes a fresh
    /// instance per test, so this lives exactly as long as it needs to.
    let store: ModelContainer = try! ModelContainer(
        for: Card.self, Folder.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    /// Deliberately hostile content: the longest realistic provenance, a
    /// four-figure price, a long grade label and a long title — the combination
    /// that broke the row.
    private func card(in context: ModelContext) -> Card {
        let c = Card(scan: CertScan(grader: .psa, certNumber: "96679812", raw: "96679812"))
        c.name = "Stephen Curry"
        c.title = "2022 Panini Donruss Optic Splash! #10 Stephen Curry Holo"
        c.set = "Panini Donruss Optic"
        c.year = 2022
        c.grade = "10 GEM MINT"
        c.cardNumber = "10"
        c.cardLadderPriceCents = 8900
        c.cardLadderLastSaleCents = 4600
        c.cardLadderLastSaleAt = Date(timeIntervalSince1970: 1_752_093_000)
        c.cardLadderConfidence = 5
        c.courtyardPriceCents = nil // the em-dash case, on screen at the same time
        c.cardLadderSales = [
            (128_050, 0, "eBay", "BestOffer"),
            (9_900, 9, "eBay", "FixedPrice"),
            (11_600, 21, "eBay", "Auction"),
            (5_000, 44, "Goldin Auctions", "Auction"),
            (12_000, 70, "eBay", "BestOffer"),
        ].map { cents, daysAgo, platform, type in
            RecentSale(priceCents: cents,
                       soldAt: Date(timeIntervalSince1970: 1_787_929_450 - Double(daysAgo) * 86_400),
                       platform: platform, listingType: type,
                       title: "2022 Optic Splash! #10 Stephen Curry", url: nil)
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

    @Test func rendersCompsList() throws {
        let card = card(in: store.mainContext)
        var source = PriceSource.cl
        let url = try render(
            SalesPanel(card: card, source: .init(get: { source }, set: { source = $0 }),
                       connected: true, onConnect: {})
                .padding(Caliper.gutter)
                .background(Caliper.bg),
            named: "comps-cl", height: 300
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Courtyard selected, with no comps — the empty state has to look
    /// deliberate rather than broken, since it is the common Courtyard case.
    /// Both meters in one frame: CL's five segments above CY's three. What to look
    /// at is the right edge — the meters end on the same pixel, because a source
    /// toggle must not shift the row's geometry.
    @Test func rendersBothConfidenceScales() throws {
        let card = card(in: store.mainContext)
        card.courtyardPriceCents = 5_071
        card.courtyardConfidence = 2
        let url = try render(
            VStack(spacing: Caliper.rowGap) {
                CardRow(card: card, source: .cl)
                CardRow(card: card, source: .cy)
            }
            .padding(Caliper.gutter)
            .background(Caliper.bg),
            named: "confidence-scales", height: 260
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rendersCourtyardEmptyState() throws {
        let card = card(in: store.mainContext)
        card.courtyardSales = []
        var source = PriceSource.cy
        let url = try render(
            SalesPanel(card: card, source: .init(get: { source }, set: { source = $0 }),
                       connected: true, onConnect: {})
                .padding(Caliper.gutter)
                .background(Caliper.bg),
            named: "comps-cy-empty", height: 160
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
