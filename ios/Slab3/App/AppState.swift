import SwiftUI
import Observation

/// The state Caliper requires to be GLOBAL rather than per-screen (README.md,
/// "State"). Two pieces are genuinely new to this codebase:
///
///   • `activeSource` — which of CL / CY leads on every row and drives the
///     sort. It changes emphasis, never visibility.
///   • `lens` — a third position ABOVE that pair (2026-09-22): our own max-buy
///     figure, available to everyone since 0.9. See `PriceLens` for why it is not
///     simply a third `PriceSource`.
///   • `filter` — one filter, shared by Cards and Export. Filtering on Cards and
///     switching to Export must carry the scope with it; re-applying it there
///     would be the bug.
///
/// Selection is here too, because the selection bar lives at app level (it rises
/// above the tab bar, which no single screen owns).
@MainActor
@Observable
final class AppState {

    /// Injected so the lens/gate tests can run against a scratch suite instead of
    /// scribbling on the test host's real preferences. One construction site.
    private let defaults: UserDefaults

    // MARK: Persisted preferences

    /// UNCHANGED by the max-buy lens, on purpose: this is still "which real source
    /// leads", it still drives all thirteen of its read sites, and max buy never
    /// writes it — which is what makes flipping to the lens and back land on the
    /// source you left.
    var activeSource: PriceSource {
        didSet { defaults.set(activeSource.rawValue, forKey: Keys.source) }
    }
    var hasSeenOnboarding: Bool {
        didSet { defaults.set(hasSeenOnboarding, forKey: Keys.onboarded) }
    }
    /// ORDERED — the order is the column order in the exported file.
    var enabledColumns: [CSVColumn] {
        didSet { defaults.set(enabledColumns.map(\.rawValue), forKey: Keys.columns) }
    }
    /// Percentage a buyer/outlet pays out, 0–100. Nil until the user sets one:
    /// there is no default rate we actually know (README.md open question 4), and
    /// a made-up rate would be a made-up dollar figure.
    var payoutPercent: Double? {
        didSet { defaults.set(payoutPercent ?? -1, forKey: Keys.payout) }
    }
    /// Opt-in "price paid" per card (2026-10-02). A few buyers offer a share of CL
    /// Value and need their real cost on the sheet; everyone else never sees the
    /// field, the row line or the CSV column. Off by default, device-local.
    var tracksPaid: Bool {
        didSet { defaults.set(tracksPaid, forKey: Keys.tracksPaid) }
    }

    // MARK: The max-buy lens

    private var storedLens: PriceLens {
        didSet { defaults.set(storedLens.rawValue, forKey: Keys.lens) }
    }

    /// Which figure leads. Selecting a real source moves `activeSource` too, so the
    /// two never disagree; selecting max buy moves neither, which is what makes it
    /// a lens over the source rather than a replacement for it.
    ///
    /// Max buy is available to every user since 0.9 (owner, 2026-10-01); it was
    /// behind a testing passcode before, which is why old installs may still hold
    /// a `caliper_testing_unlocked` key that nothing reads.
    ///
    /// Only max buy is remembered in `storedLens`; a source lens is always READ from
    /// `activeSource`. Two things write that source without touching the lens —
    /// Settings' "Default emphasis" and SalesPanel's comps toggle — and a stored
    /// `.cl` would then lead every row with CL while the sort, the totals and the
    /// detail hero followed CY. Deriving it makes that disagreement unrepresentable.
    var lens: PriceLens {
        get { storedLens == .maxBuy ? .maxBuy : PriceLens(activeSource) }
        set {
            storedLens = newValue
            if let source = newValue.source { activeSource = source }
        }
    }

    var availableLenses: [PriceLens] { PriceLens.allCases }
    var isMaxBuy: Bool { lens == .maxBuy }

    /// The columns this build may actually EMIT: the user's order, minus the
    /// lot-only columns outside a lot. `enabledColumns` stays the raw persisted
    /// order.
    var exportColumns: [CSVColumn] {
        let allowed = CSVColumn.available(tracksPaid: tracksPaid)
        return enabledColumns.filter(allowed.contains)
    }

    // MARK: Session state

    /// The group new scans file into, by `Folder.localId` ("" = none). Moved here
    /// from ScanScreen (teams-first plan) because it is also the team's CURRENT
    /// LOT — Teams, the Scan bar and Team activity read it (CurrentLot). Same
    /// UserDefaults key as before, so a chosen group survives the update.
    var scanTargetId: String {
        didSet { defaults.set(scanTargetId, forKey: Keys.scanGroup) }
    }
    /// The user picked None on purpose. Stops the single-open-lot auto-pick
    /// (ScanTargetRule) from overriding a deliberate choice.
    var scanTargetExplicitNone: Bool {
        didSet { defaults.set(scanTargetExplicitNone, forKey: Keys.scanGroupNone) }
    }
    var scanTargetUUID: UUID? { UUID(uuidString: scanTargetId) }

    var tab: AppTab = .scan
    /// The Teams tab's pushed screens (lot, builder, activity…). The one tab with a
    /// path, because other screens send the user INTO it (Cards' lot line, the Scan
    /// bar) and Team activity drills three levels deep.
    var teamsPath: [TeamsRoute] = []
    /// The user has picked a tab this session — after that the app never moves
    /// them on its own (LaunchLanding).
    var tabTouched = false
    /// Was this device on a team at the last successful load? Lets a team member's
    /// launch show the Teams tab — and land on it — from the first frame, instead of
    /// four tabs flicking to five once the team loads. Cleared on sign-out.
    var onTeamHint: Bool {
        didSet { defaults.set(onTeamHint, forKey: Keys.teamHint) }
    }

    /// The tab bar's tabs. Teams only for someone on a team (teams-first plan, D3):
    /// everyone else keeps exactly the four-tab app. Before the first answer — or
    /// after a failed load at a show with no signal — the last known answer holds.
    var visibleTabs: [AppTab] {
        let onTeam = team.team != nil || (!team.lastLoadOK && onTeamHint)
        return AppTab.visible(teamsAvailable: TeamsFeature.isAvailable, onTeam: onTeam)
    }
    /// Bumped when the tab ALREADY showing is tapped again. Screens that push a
    /// detail watch it and pop back to their list — the standard iOS reselect.
    var tabReselected = 0
    var filter: CardFilter = .all
    var selection: Set<UUID> = []
    var isSelecting = false
    var sort: SortOrder = .recent
    var search = ""

    /// The user's team, if any. App-level because the lot selector on Scan, the
    /// lot view on Cards and Settings all read it (plan §4b). Inert — no request,
    /// no state — unless `TeamsFeature.isAvailable`.
    let team = TeamStore()
    /// The team's lots, their buy ranges and the range library. Same gate.
    let lots = LotStore()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let source = PriceSource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .cl
        activeSource = source
        hasSeenOnboarding = defaults.bool(forKey: Keys.onboarded)
        scanTargetId = defaults.string(forKey: Keys.scanGroup) ?? ""
        onTeamHint = defaults.bool(forKey: Keys.teamHint)
        scanTargetExplicitNone = defaults.bool(forKey: Keys.scanGroupNone)
        let saved = (defaults.array(forKey: Keys.columns) as? [String]) ?? []
        let restored = saved.compactMap(CSVColumn.init(rawValue:))
        enabledColumns = restored.isEmpty ? CSVColumn.defaults : restored
        let stored = defaults.double(forKey: Keys.payout)
        payoutPercent = stored > 0 ? stored : nil
        tracksPaid = defaults.bool(forKey: Keys.tracksPaid)

        storedLens = PriceLens(rawValue: defaults.string(forKey: Keys.lens) ?? "") ?? PriceLens(source)
        // A team member lands on Teams (D1); everyone else on Scan, as always.
        if TeamsFeature.isAvailable && onTeamHint { tab = .teams }
    }

    // MARK: Selection

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    func endSelecting() {
        isSelecting = false
        selection.removeAll()
    }

    /// Payout for a gross value, or nil while no rate is configured.
    func payoutCents(on grossCents: Int) -> Int? {
        guard let payoutPercent else { return nil }
        return Int((Double(grossCents) * payoutPercent / 100).rounded())
    }

    /// What this card cost, or nil when price paid is off or none was entered. The
    /// ONE read of `paidCents`, so switching the feature off makes every
    /// consumer ignore stored values at once — without clearing them.
    func paidCents(_ card: Card) -> Int? {
        tracksPaid ? card.paidCents : nil
    }

    private enum Keys {
        static let source = "caliper_active_source"
        static let lens = "caliper_price_lens"
        static let onboarded = "caliper_seen_onboarding"
        static let columns = "caliper_csv_columns"
        static let payout = "caliper_payout_percent"
        static let tracksPaid = "caliper_track_paid"
        static let scanGroup = "caliper_scan_group"
        static let teamHint = "caliper_team_hint"
        static let scanGroupNone = "caliper_scan_group_none"
    }
}

/// Four destinations — five for someone on a team, with Teams in the centre
/// (teams-first plan, D2/D3). Never more.
enum AppTab: String, CaseIterable, Identifiable {
    case scan, cards, teams, export, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "Scan"
        case .cards: return "Cards"
        case .teams: return "Teams"
        case .export: return "Export"
        case .settings: return "Settings"
        }
    }
    var glyph: String {
        switch self {
        case .scan: return "barcode.viewfinder"
        case .cards: return "square.stack"
        case .teams: return "person.2"
        case .export: return "square.and.arrow.up"
        case .settings: return "slider.horizontal.3"
        }
    }

    /// Everyone not on a team gets exactly the four tabs the shipped app has.
    static func visible(teamsAvailable: Bool, onTeam: Bool) -> [AppTab] {
        allCases.filter { $0 != .teams || (teamsAvailable && onTeam) }
    }
}

/// A screen pushed on the Teams tab.
enum TeamsRoute: Hashable {
    case lot(UUID)
    case builder(UUID?)
    case activity
    case activityMembers(UUID)
    case receipt(lotId: UUID, userId: UUID)
    case claim(UUID)
    case members
    case library
}

/// One filter, shared by Cards and Export. Buy ranges are named in the design but
/// nothing in it (or in the client's reference) ever authors one — README.md open
/// question 3 — so they are deliberately absent rather than faked.
enum CardFilter: Hashable {
    case all
    case group(UUID)
    case ungrouped
    case unmatched
}

enum SortOrder: String, CaseIterable, Identifiable {
    case recent, price, name
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: return "Recent"
        case .price: return "Price"
        case .name: return "Name"
        }
    }
}
