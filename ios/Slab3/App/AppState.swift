import SwiftUI
import Observation

/// The state Caliper requires to be GLOBAL rather than per-screen (README.md,
/// "State"). Two pieces are genuinely new to this codebase:
///
///   • `activeSource` — which of CL / CY leads on every row and drives the
///     sort. It changes emphasis, never visibility.
///   • `filter` — one filter, shared by Cards and Export. Filtering on Cards and
///     switching to Export must carry the scope with it; re-applying it there
///     would be the bug.
///
/// Selection is here too, because the selection bar lives at app level (it rises
/// above the tab bar, which no single screen owns).
@MainActor
@Observable
final class AppState {

    // MARK: Persisted preferences

    var activeSource: PriceSource {
        didSet { UserDefaults.standard.set(activeSource.rawValue, forKey: Keys.source) }
    }
    var hasSeenOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasSeenOnboarding, forKey: Keys.onboarded) }
    }
    /// ORDERED — the order is the column order in the exported file.
    var enabledColumns: [CSVColumn] {
        didSet { UserDefaults.standard.set(enabledColumns.map(\.rawValue), forKey: Keys.columns) }
    }
    /// Percentage a buyer/outlet pays out, 0–100. Nil until the user sets one:
    /// there is no default rate we actually know (README.md open question 4), and
    /// a made-up rate would be a made-up dollar figure.
    var payoutPercent: Double? {
        didSet { UserDefaults.standard.set(payoutPercent ?? -1, forKey: Keys.payout) }
    }

    // MARK: Session state

    var tab: AppTab = .scan
    var filter: CardFilter = .all
    var selection: Set<UUID> = []
    var isSelecting = false
    var sort: SortOrder = .recent
    var search = ""

    init() {
        let defaults = UserDefaults.standard
        activeSource = PriceSource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .cl
        hasSeenOnboarding = defaults.bool(forKey: Keys.onboarded)
        let saved = (defaults.array(forKey: Keys.columns) as? [String]) ?? []
        let restored = saved.compactMap(CSVColumn.init(rawValue:))
        enabledColumns = restored.isEmpty ? CSVColumn.defaults : restored
        let stored = defaults.double(forKey: Keys.payout)
        payoutPercent = stored > 0 ? stored : nil
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

    private enum Keys {
        static let source = "caliper_active_source"
        static let onboarded = "caliper_seen_onboarding"
        static let columns = "caliper_csv_columns"
        static let payout = "caliper_payout_percent"
    }
}

/// Four destinations, no more (README.md, "Tab bar").
enum AppTab: String, CaseIterable, Identifiable {
    case scan, cards, export, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "Scan"
        case .cards: return "Cards"
        case .export: return "Export"
        case .settings: return "Settings"
        }
    }
    var glyph: String {
        switch self {
        case .scan: return "barcode.viewfinder"
        case .cards: return "square.stack"
        case .export: return "square.and.arrow.up"
        case .settings: return "slider.horizontal.3"
        }
    }
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
