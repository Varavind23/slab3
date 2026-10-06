import Testing
import SwiftUI
@testable import Slab3

/// Renders 0.9's lot-basis UI to PNGs under $TMPDIR/slabs-render/ — and, like every
/// render suite here, asserts only that the file exists, so LOOK at them.
///
/// What to look at: the MAX · CL · CY bar sits under a header without crowding it;
/// a lot box names the figure it totals; and a teammate's row carries BOTH sources'
/// values recorded at claim, with an em dash (never $0) where one had none.
@MainActor
struct LotBasisRenderTests {

    private func render(_ view: some View, named name: String, height: CGFloat) throws -> URL {
        let renderer = ImageRenderer(content: view.frame(width: 393, height: height)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slabs-render")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let data = renderer.uiImage?.pngData() else { throw RenderError.failed }
        try data.write(to: url)
        print("RENDERED \(url.path)")
        return url
    }

    enum RenderError: Error { case failed }

    private func claim(cl: Int?, cy: Int?, max: Int?) -> TeamClaim {
        TeamClaim(id: UUID(), lotId: UUID(), rangeId: nil, cert: "96679812", grader: "psa", gradeLabel: "10",
                  priceCents: cl, clConfidence: 4, label: "2022 Panini Donruss Optic Splash! #10 Stephen Curry",
                  player: "Stephen Curry", cardSet: "Optic Splash!", cardYear: "2022", cardNumber: "10",
                  imageUrl: nil, buyerId: UUID(), state: "confirmed", scannedAt: "2026-10-04T10:42:00Z",
                  cyPriceCents: cy, maxBuyCents: max)
    }

    @Test func rendersTeamActivityUnderEachView() throws {
        let lot = Lot(id: UUID(), name: "Weekend 10/4", deadline: Date().addingTimeInterval(200_000),
                      status: .active, createdAt: Date(), valueBasis: .cy)
        let claims = [claim(cl: 5000, cy: 15080, max: 4100), claim(cl: 2000, cy: nil, max: nil)]
        let url = try render(
            VStack(alignment: .leading, spacing: 0) {
                ForEach([PriceLens.maxBuy, .cl, .cy]) { lens in
                    let box = TeamActivity.boxes(lots: [lot], claimsByLot: [lot.id: claims], lens: lens)[0]
                    ScreenHeader(context: "Leads · " + lens.atClaim, title: "Team activity") {
                        Text("Done").font(.mono(10, .medium)).foregroundStyle(Caliper.textSecondary)
                    }
                    ActivityLensBar(lens: lens) { _ in }
                    HStack(alignment: .top, spacing: Caliper.space5) {
                        LotBoxView(box: box, lens: lens, isSelected: true) {}
                        Text(TeamActivity.coverage(cards: box.cards, valued: box.valued, lens: lens) ?? "complete")
                            .caliperMeta()
                    }
                    .padding(Caliper.gutter)
                }
            }
            .background(Caliper.bg),
            named: "lot-basis-activity", height: 1080)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rendersATeammateRowWithBothRecordedValues() throws {
        let url = try render(
            VStack(spacing: Caliper.rowGap) {
                TeammateClaimRow(claim: claim(cl: 5000, cy: 15080, max: 4100), buyer: "JUSTIN")
                TeammateClaimRow(claim: claim(cl: 2000, cy: nil, max: nil), buyer: "SAM")
            }
            .padding(Caliper.gutter)
            .background(Caliper.bg),
            named: "lot-basis-teammate-rows", height: 240)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
