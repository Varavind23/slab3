import Testing
import Foundation
@testable import Slab3

/// The rules that keep the max-buy lens a LENS over the source rather than a third
/// source, and (since 0.9, when the testing passcode went) available to everyone.
///
/// These run against a scratch `UserDefaults` suite rather than `.standard` — the
/// lens is a persisted preference, and a test that scribbled on the real one would
/// change the behaviour of the app on the machine running it.
@MainActor
struct PriceLensTests {

    /// A fresh suite per test, so nothing leaks between them.
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "slabs.test.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // ── The lens sits above the source ────────────────────────────────────────

    @Test func maxBuyRemembersTheSourceUnderneath() {
        let app = AppState(defaults: freshDefaults())
        app.lens = .cy
        app.lens = .maxBuy
        // Max buy writes no source, which is the whole reason it is a lens: the
        // comps panel, PriceRest and the export total all still have a real source
        // to read, and flipping back lands where the user left.
        #expect(app.activeSource == .cy)
        #expect(app.isMaxBuy)
    }

    @Test func choosingARealSourceMovesBoth() {
        let app = AppState(defaults: freshDefaults())
        app.lens = .maxBuy
        app.lens = .cl
        #expect(app.activeSource == .cl)
        #expect(!app.isMaxBuy)
    }

    @Test func theSalesToggleDoesNotLeaveTheLens() {
        // SalesPanel writes activeSource directly to switch which comps it shows.
        // That must not knock the user off max buy — the two controls answer
        // different questions.
        let app = AppState(defaults: freshDefaults())
        app.lens = .maxBuy
        app.activeSource = .cy
        #expect(app.isMaxBuy)
    }

    @Test func settingsEmphasisMovesTheLens() {
        // Settings' "Default emphasis" writes activeSource alone. A stored CL lens
        // used to survive that, so the header led with CL while the sort and every
        // total followed CY — and both keys persisted, so a relaunch kept it wrong.
        let defaults = freshDefaults()
        let app = AppState(defaults: defaults)
        app.lens = .cl
        app.activeSource = .cy
        #expect(app.lens == .cy)
        #expect(AppState(defaults: defaults).lens == .cy, "and it survives a launch")
    }

    @Test func theSalesToggleMovesASourceLens() {
        // Under CL/CY the detail hero follows the comps toggle (the 2026-08-31
        // rule) — two sources' figures on one screen is the misreading it prevents.
        let app = AppState(defaults: freshDefaults())
        app.lens = .cl
        app.activeSource = .cy
        #expect(app.lens == .cy)
        #expect(!app.isMaxBuy)
    }

    // ── Everyone gets it (0.9) ────────────────────────────────────────────────

    @Test func theMaxBuySegmentIsLeftmostForEveryone() {
        let app = AppState(defaults: freshDefaults())
        #expect(app.availableLenses == [.maxBuy, .cl, .cy])
    }

    @Test func aFreshInstallStillLeadsWithASource() {
        // Available is not chosen: nobody lands on max buy without pressing it.
        let app = AppState(defaults: freshDefaults())
        #expect(!app.isMaxBuy)
    }

    @Test func aMaxBuyLensSurvivesALaunch() {
        let defaults = freshDefaults()
        defaults.set(PriceLens.maxBuy.rawValue, forKey: "caliper_price_lens")
        #expect(AppState(defaults: defaults).isMaxBuy)
    }

    @Test func theRetiredGateKeyIsIgnored() {
        // A 0.8 install that once unlocked and then LOCKED again carries
        // `caliper_testing_unlocked = false`. That must no longer hide anything.
        let defaults = freshDefaults()
        defaults.set(false, forKey: "caliper_testing_unlocked")
        defaults.set(PriceLens.maxBuy.rawValue, forKey: "caliper_price_lens")
        let app = AppState(defaults: defaults)
        #expect(app.isMaxBuy)
        #expect(app.availableLenses.count == 3)
    }

    // ── Geometry ──────────────────────────────────────────────────────────────

    @Test func aSourceOnlyToggleIsTwoSegments() {
        #expect(LensToggle.width(of: PriceLens.sources) == 60)
    }

    @Test func theFullToggleIsThreeSegmentsAndNoMore() {
        #expect(LensToggle.width(of: PriceLens.allCases) == 90)
    }

    // ── The written-out label ─────────────────────────────────────────────────

    @Test func theSegmentIsAbbreviatedAndTheFigureIsNot() {
        // "MAX" is all a 30pt segment holds; everywhere with room spells it out,
        // because the person being sold to reads this screen too.
        #expect(PriceLens.maxBuy.label == "MAX")
        #expect(PriceLens.maxBuy.rowLabel == "MAX BUY")
    }

    @Test func maxBuyHasNoSourceAndNoSourceHue() {
        #expect(PriceLens.maxBuy.source == nil)
        #expect(PriceLens.maxBuy.hue == Caliper.textPrimary)
        #expect(PriceLens.cl.hue == PriceSource.cl.hue)
    }

    // ── The CSV column ────────────────────────────────────────────────────────

    @Test func theMaxBuyColumnIsOfferedButNeverOnByDefault() {
        #expect(CSVColumn.available().contains(.maxBuy))
        // The CSV goes to buyers; stating the most you would pay is opt-in.
        #expect(!CSVColumn.defaults.contains(.maxBuy))

        let app = AppState(defaults: freshDefaults())
        app.enabledColumns = [.cert, .maxBuy, .clPrice]
        #expect(app.exportColumns == [.cert, .maxBuy, .clPrice])
    }
}
