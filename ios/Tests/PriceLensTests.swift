import Testing
import Foundation
@testable import Slab3

/// The rules that keep the max-buy lens from ever being visible to someone who has
/// not unlocked it, and from ever stranding someone who locks it again.
///
/// These run against a scratch `UserDefaults` suite rather than `.standard` — the
/// gate and the lens are both persisted preferences, and a test that scribbled on
/// the real ones would change the behaviour of the app on the machine running it.
@MainActor
struct PriceLensTests {

    /// A fresh suite per test, so nothing leaks between them.
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "slabs.test.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func unlockedState(_ defaults: UserDefaults) -> AppState {
        defaults.set(true, forKey: TestingGate.unlockedKey)
        let app = AppState(defaults: defaults)
        app.testingUnlocked = true
        return app
    }

    // ── The lens sits above the source ────────────────────────────────────────

    @Test func maxBuyRemembersTheSourceUnderneath() {
        let app = unlockedState(freshDefaults())
        app.lens = .cy
        app.lens = .maxBuy
        // Max buy writes no source, which is the whole reason it is a lens: the
        // comps panel, PriceRest and the export total all still have a real source
        // to read, and flipping back lands where the user left.
        #expect(app.activeSource == .cy)
        #expect(app.isMaxBuy)
    }

    @Test func choosingARealSourceMovesBoth() {
        let app = unlockedState(freshDefaults())
        app.lens = .maxBuy
        app.lens = .cl
        #expect(app.activeSource == .cl)
        #expect(!app.isMaxBuy)
    }

    @Test func theSalesToggleDoesNotLeaveTheLens() {
        // SalesPanel writes activeSource directly to switch which comps it shows.
        // That must not knock the user off max buy — the two controls answer
        // different questions.
        let app = unlockedState(freshDefaults())
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
        let app = unlockedState(freshDefaults())
        app.lens = .cl
        app.activeSource = .cy
        #expect(app.lens == .cy)
        #expect(!app.isMaxBuy)
    }

    // ── The gate ──────────────────────────────────────────────────────────────

    @Test func theMaxBuySegmentIsLeftmostAndOnlyWhenUnlocked() {
        #expect(PriceLens.available(unlocked: false) == [.cl, .cy])
        #expect(PriceLens.available(unlocked: true).first == .maxBuy)
        #expect(PriceLens.available(unlocked: true).count == 3)
    }

    @Test func aFreshUnlockDoesNotSwitchLenses() {
        let defaults = freshDefaults()
        let app = AppState(defaults: defaults)
        app.lens = .cy
        app.testingUnlocked = true
        // Unlocking adds a segment. It does not press it.
        #expect(app.lens == .cy)
        #expect(app.availableLenses.count == 3)
    }

    @Test func lensFallsBackWhenTheGateLocks() {
        let defaults = freshDefaults()
        let app = unlockedState(defaults)
        app.lens = .cy
        app.lens = .maxBuy
        #expect(app.isMaxBuy)

        app.testingUnlocked = false

        // Back to the source underneath, and the stored key no longer says max buy —
        // otherwise the next launch would restore a lens with no segment to show it.
        #expect(app.lens == .cy)
        #expect(!app.isMaxBuy)
        #expect(defaults.string(forKey: "caliper_price_lens") != PriceLens.maxBuy.rawValue)
    }

    @Test func aLockedMaxBuyLensDoesNotSurviveALaunch() {
        // Seed the state a crash mid-lock, or a defaults edit, could leave behind.
        let defaults = freshDefaults()
        defaults.set(PriceLens.maxBuy.rawValue, forKey: "caliper_price_lens")
        defaults.set(PriceSource.cy.rawValue, forKey: "caliper_active_source")
        defaults.set(false, forKey: TestingGate.unlockedKey)

        let app = AppState(defaults: defaults)
        #expect(app.lens == .cy)
        #expect(defaults.string(forKey: "caliper_price_lens") == PriceLens.cy.rawValue,
                "the key is rewritten, not just read past")
    }

    @Test func anUnlockedMaxBuyLensSurvivesALaunch() {
        let defaults = freshDefaults()
        defaults.set(PriceLens.maxBuy.rawValue, forKey: "caliper_price_lens")
        defaults.set(true, forKey: TestingGate.unlockedKey)
        #expect(AppState(defaults: defaults).isMaxBuy)
    }

    // ── Geometry ──────────────────────────────────────────────────────────────

    @Test func aLockedToggleIsExactlyAsWideAsItWas() {
        // 60pt, two 30pt segments. No locked user's header may move because of a
        // feature they cannot see.
        #expect(LensToggle.width(of: PriceLens.sources) == 60)
    }

    @Test func theUnlockedToggleAddsOneSegmentAndNoMore() {
        #expect(LensToggle.width(of: PriceLens.available(unlocked: true)) == 90)
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

    // ── The CSV column rides the same gate ────────────────────────────────────

    @Test func theMaxBuyColumnIsHiddenAndUnexportableWhileLocked() {
        #expect(!CSVColumn.available(testingUnlocked: false).contains(.maxBuy))
        #expect(CSVColumn.available(testingUnlocked: true).contains(.maxBuy))
        #expect(!CSVColumn.defaults.contains(.maxBuy), "never on by default")

        // Enabled while unlocked, then locked: the column stops being exported, but
        // the user's column ORDER is left intact.
        let app = unlockedState(freshDefaults())
        app.enabledColumns = [.cert, .maxBuy, .clPrice]
        #expect(app.exportColumns == [.cert, .maxBuy, .clPrice])

        app.testingUnlocked = false
        #expect(app.exportColumns == [.cert, .clPrice])
        #expect(app.enabledColumns == [.cert, .maxBuy, .clPrice])
    }
}
