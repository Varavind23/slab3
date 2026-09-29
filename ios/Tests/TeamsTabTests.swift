import Testing
import SwiftUI
import UIKit
@testable import Slab3

/// The Teams tab (teams-first plan, phase 2).
///
/// The first test is the promise to everyone NOT on a team: the shipped four-tab
/// app, exactly. The renders are for looking at — $TMPDIR/slabs-render/teams-*.png
/// (the SIMULATOR's $TMPDIR; the test log prints each path). Layout bugs have
/// shipped green before because only file existence was asserted, so the tab bar's
/// fit on the narrowest phone is asserted as a measurement.
@MainActor
struct TeamsTabTests {

    @Test func someoneNotOnATeamGetsExactlyTheFourShippedTabs() {
        let shipped: [AppTab] = [.scan, .cards, .export, .settings]
        #expect(AppTab.visible(teamsAvailable: false, onTeam: false) == shipped)
        #expect(AppTab.visible(teamsAvailable: false, onTeam: true) == shipped,
                "a shipped build (no local backend) never shows Teams, whatever it is told")
        #expect(AppTab.visible(teamsAvailable: true, onTeam: false) == shipped)
        #expect(AppTab.visible(teamsAvailable: true, onTeam: true) == [.scan, .cards, .teams, .export, .settings],
                "on a team: five, Teams in the centre")
    }

    @Test func fiveTabLabelsFitTheNarrowestPhone() {
        // 375pt (iPhone SE / mini) split five ways.
        let column: CGFloat = 375 / 5
        for tab in AppTab.allCases {
            let width = UIHostingController(rootView: Text(tab.title).caliperLabel())
                .sizeThatFits(in: CGSize(width: 1_000, height: 100)).width
            #expect(width <= column, "\(tab.title) is \(width)pt in a \(column)pt column")
        }
    }

    // MARK: Renders

    private let lotId = UUID(), me = UUID(), mate = UUID()

    private func range(_ lo: Int64, _ hi: Int64, cards: Int, budget: Int64) -> BuyRange {
        BuyRange(id: UUID(), name: "\(lo)", valueMinCents: lo, valueMaxCents: hi, gradeMin: 7, gradeMax: 10,
                 clConfMin: nil, clConfMax: nil, yearMin: nil, yearMax: nil,
                 maxCards: cards, budgetCents: budget, notes: nil)
    }

    private func seeded(lead: Bool, withLots: Bool) -> (TeamStore, LotStore, Lot?) {
        let team = TeamStore()
        team.seedForPreview(team: .init(id: UUID(), name: "Buyers", joinCode: "K7Q2MX"),
                            members: [.init(userId: me, role: lead ? .lead : .buyer, displayName: "Justin"),
                                      .init(userId: mate, role: lead ? .buyer : .lead, displayName: "Maria")],
                            myUserId: me)
        let lots = LotStore()
        guard withLots else {
            lots.seedForPreview(lots: [], ranges: [:], usage: [:], loadedAt: Date())
            return (team, lots, nil)
        }
        let lot = Lot(id: lotId, name: "Weekend 10/4", deadline: Date().addingTimeInterval(187_000),
                      status: .active, createdAt: Date(), banner: "PSA only")
        let other = Lot(id: UUID(), name: "Show 10/11", deadline: Date().addingTimeInterval(432_000),
                        status: .active, createdAt: Date())
        let low = range(0, 10_000, cards: 400, budget: 4_510_000)
        let high = range(10_000, 24_000, cards: 120, budget: 4_162_500)
        let full = range(24_000, 50_000, cards: 20, budget: 800_000)
        let usage: [UUID: RangeUsage] = [
            low.id: .init(rangeId: low.id, cards: 231, usedCents: 1_733_243),
            high.id: .init(rangeId: high.id, cards: 110, usedCents: 812_000),
            full.id: .init(rangeId: full.id, cards: 20, usedCents: 640_000),
        ]
        lots.seedForPreview(lots: [lot, other], ranges: [lotId: [low, high, full], other.id: [low]],
                            usage: usage, loadedAt: Date())
        return (team, lots, lot)
    }

    @Test func rendersABuyersTeamsTab() throws {
        let (team, lots, lot) = seeded(lead: false, withLots: true)
        let url = try render(TeamsContent(team: team, lots: lots, current: lot, showIntro: true, send: { _ in }),
                             named: "teams-buyer", height: 1_400)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rendersALeadWithNoLots() throws {
        let (team, lots, _) = seeded(lead: true, withLots: false)
        let url = try render(TeamsContent(team: team, lots: lots, current: nil, send: { _ in }),
                             named: "teams-lead-empty", height: 900)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rendersTheTabBarWithFiveTabs() throws {
        let bar = CaliperTabBar(tab: .constant(.teams), tabs: AppTab.visible(teamsAvailable: true, onTeam: true))
        let url = try render(bar, named: "teams-tab-bar-375", width: 375, height: 70)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func render(_ view: some View, named name: String, width: CGFloat = 393,
                        height: CGFloat) throws -> URL {
        // No ScrollView: ImageRenderer draws a scroll view's content blank.
        let renderer = ImageRenderer(content: view
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .frame(height: height)
            .background(Caliper.bg)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slabs-render")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        try #require(renderer.uiImage?.pngData()).write(to: url)
        print("RENDERED \(url.path)")
        return url
    }
}
