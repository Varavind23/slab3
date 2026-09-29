import Foundation
import SwiftUI
import Testing
@testable import Slab3

/// The lot dashboard (plan §8): its numbers are derived, so they are pinned here,
/// and the screen is rendered so it can be held up against the allocation screen
/// it mirrors.
///
/// Output: $TMPDIR/slabs-render/lot-dashboard.png — LOOK at it: band rows read
/// `$0 – $100 … $x / $y`, rules, bar, `N% used`, `N buckets`; the open band shows
/// the chart with a bucket picked.
@MainActor
struct LotDashboardTests {
    private let lotId = UUID()
    private let pokemon = UUID(), sports = UUID()

    private func range(_ min: Int64, _ max: Int64?, budget: Int64, band: UUID?, grade: Double = 7,
                       conf: Int? = nil, cards: Int = 400) -> BuyRange {
        BuyRange(id: UUID(), name: BuyRangeText.value(min: min, max: max), valueMinCents: min, valueMaxCents: max,
                 gradeMin: grade, gradeMax: 10, clConfMin: conf, clConfMax: nil, yearMin: nil, yearMax: nil,
                 maxCards: cards, budgetCents: budget, notes: nil, bandId: band)
    }

    @Test func bandsRollUpTheirBuckets() {
        let a = range(0, 5_000, budget: 2_000_000, band: pokemon)
        let b = range(5_000, 10_000, budget: 6_672_500, band: pokemon)
        let usage = [a.id: RangeUsage(rangeId: a.id, cards: 10, usedCents: 500_000),
                     b.id: RangeUsage(rangeId: b.id, cards: 20, usedCents: 1_512_387)]
        let cats = LotDashboard.build(bands: [LotBand(id: pokemon, lotId: lotId, category: "Pokémon", sortOrder: 0)],
                                      ranges: [b, a], usage: usage)
        let band = cats[0].bands[0]
        #expect(band.valueLabel == "$0 – $100", "the span comes from its buckets")
        #expect(band.usedCents == 2_012_387)
        #expect(band.allocatedCents == 8_672_500)
        #expect(LotDashboard.usedOfAllocated(band.usedCents, band.allocatedCents) == "$20,123.87 / $86,725")
        #expect(band.percentUsed == 23)
        #expect(band.bucketCountLabel == "2 buckets")
        #expect(band.buckets.map(\.range.valueMinCents) == [0, 5_000], "buckets in price order")
        #expect(band.rules == "7+ CERTS")
        #expect(cats[0].gradeLine == "SLABS · GRADE 7+")
    }

    @Test func rulesUseTheAllocationScreensWords() {
        let shared = [range(10_000, 12_000, budget: 1, band: nil, conf: 4),
                      range(12_000, 14_000, budget: 1, band: nil, conf: 4)]
        #expect(LotDashboard.rules(shared) == "CONF 4+ · 7+ CERTS")
        let mixed = [range(0, 1, budget: 1, band: nil, grade: 7), range(1, 2, budget: 1, band: nil, grade: 8)]
        #expect(LotDashboard.rules(mixed) == "", "a band shows only what every bucket shares")
        #expect(LotDashboard.rules([range(0, 1, budget: 1, band: nil, grade: 1)]) == "",
                "grade 1–10 is no rule at all")
    }

    @Test func categoriesSplitAndLooseBucketsStandAlone() {
        let p = range(0, 10_000, budget: 100, band: pokemon)
        let s = range(0, 10_000, budget: 100, band: sports)
        let loose = range(50_000, nil, budget: 100, band: nil)
        let cats = LotDashboard.build(
            bands: [LotBand(id: pokemon, lotId: lotId, category: "Pokémon", sortOrder: 0),
                    LotBand(id: sports, lotId: lotId, category: "Sports", sortOrder: 1)],
            ranges: [p, s, loose], usage: [:])
        #expect(cats.map(\.title) == ["Pokémon", "Sports", "All cards"])
        #expect(cats[2].bands[0].valueLabel == "$500+")
        #expect(cats[0].bands[0].usedCents == 0, "nothing bought reads as $0 used, not missing")
    }

    @Test func overspendIsTruthfulButTheBarStopsAtFull() {
        let r = range(0, 100, budget: 45_100_00, band: nil)
        let cats = LotDashboard.build(bands: [], ranges: [r],
                                      usage: [r.id: RangeUsage(rangeId: r.id, cards: 1, usedCents: 50_100_00)])
        #expect(cats[0].bands[0].percentUsed == 111)
        #expect(cats[0].bands[0].fraction == 1)
    }

    @Test func countdownReadsLikeTheOtherScreen() {
        let now = Date(timeIntervalSince1970: 0)
        let seconds: TimeInterval = 429_454   // 4d 23:17:34
        let text = LotDashboard.countdown(to: now.addingTimeInterval(seconds), now: now)
        #expect(text == "4d 23:17:34")
        #expect(LotDashboard.countdown(to: now.addingTimeInterval(65), now: now) == "00:01:05")
        #expect(LotDashboard.countdown(to: now, now: now) == nil, "past the deadline there is no countdown")
    }

    // MARK: Rendered

    @Test func rendersTheDashboard() throws {
        let store = LotStore()
        let lot = Lot(id: lotId, name: "Show 7/24", deadline: Date().addingTimeInterval(429_454),
                      status: .active, createdAt: Date(), banner: "Only accepting PSA slabs: no CGC, no BGS")
        let low = pokemon, high = UUID()
        var ranges = [range(0, 3_000, budget: 2_600_000, band: low),
                      range(3_000, 5_000, budget: 2_800_000, band: low),
                      range(5_000, 10_000, budget: 3_272_500, band: low)]
        let highBuckets: [(Int64, Int64, Int64)] = [(10_000, 12_000, 950_000), (12_000, 14_000, 960_000),
            (14_000, 16_000, 120_000), (16_000, 18_000, 540_000), (18_000, 20_000, 340_000),
            (20_000, 22_000, 330_000), (22_000, 24_000, 116_000)]
        ranges += highBuckets.map { range($0.0, $0.1, budget: $0.2, band: high, conf: 4) }
        var usage: [UUID: RangeUsage] = [:]
        let spent: [Int64] = [600_000, 900_000, 512_387, 420_000, 130_000, 120_000, 330_000, 150_000, 150_000, 116_000]
        for (r, cents) in zip(ranges, spent) { usage[r.id] = RangeUsage(rangeId: r.id, cards: Int(cents / 8_000), usedCents: cents) }
        let reported = try JSONDecoder().decode(RangeReport.self, from: Data(
            ("{\"lot_buy_range_id\":\"" + ranges[0].id.uuidString + "\",\"used_cents\":520000,\"card_count\":61,\"reported_at\":\"2026-09-24T09:12:00Z\"}").utf8))
        store.seedForPreview(
            lots: [lot], ranges: [lotId: ranges],
            bands: [lotId: [LotBand(id: low, lotId: lotId, category: "Pokémon", sortOrder: 0),
                            LotBand(id: high, lotId: lotId, category: "Pokémon", sortOrder: 1)]],
            usage: usage, reports: [ranges[0].id: reported])

        // No ScrollView: ImageRenderer draws a scroll view's content blank.
        let lastBucket = ranges.last!.id
        let view = LotDashboardView(lot: lot, lots: store, expanded: [high], selected: [high: lastBucket])
            .padding(Caliper.gutter)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Caliper.bg)
        let renderer = ImageRenderer(content: view.frame(width: 393, height: 1100).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slabs-render")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("lot-dashboard.png")
        let data = try #require(renderer.uiImage?.pngData())
        try data.write(to: url)
        print("RENDERED \(url.path)")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
