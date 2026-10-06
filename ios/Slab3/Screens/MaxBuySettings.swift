import SwiftUI

/// The team-side inputs to max buy (0.9), pushed in by TeamStore and LotStore on
/// every load: the lead's skew and margin, and which lots count in Courtyard value.
/// Observable so that rows reading it inside `body` redraw when a lead changes it.
///
/// REMEMBERED ACROSS LAUNCHES (workflow test 2026-10-06). Buyers work shows with no
/// signal, and a cold launch there never loads the team: in memory only, a member's
/// max buy fell back to their PHONE's skew and margin — possibly looser than the
/// lead's, the one thing M2 forbids — and a CY lot's cards priced on Card Ladder.
/// So the last loaded answer is kept (`remember`, after each successful load), put
/// back at launch (`restore`), and cleared on sign-out (`forget`). Explicit calls
/// rather than a didSet, so tests that set the policy never write defaults.
@MainActor
@Observable
final class MaxBuyTeamPolicy {
    static let shared = MaxBuyTeamPolicy()

    struct Knobs: Equatable, Codable { var skew: Double; var margin: Double }

    var knobs: Knobs?
    /// lot id → its basis, for every lot this phone can see.
    var basisByLot: [UUID: ValueBasis] = [:]

    static let storageKey = "caliper_team_max_buy_policy"
    private struct Stored: Codable { var knobs: Knobs?; var basisByLot: [UUID: ValueBasis] }

    func remember(in defaults: UserDefaults = .standard) {
        let data = try? JSONEncoder().encode(Stored(knobs: knobs, basisByLot: basisByLot))
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Only fills what no load has filled yet: a load that already answered wins.
    func restore(from defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        if knobs == nil { knobs = stored.knobs }
        if basisByLot.isEmpty { basisByLot = stored.basisByLot }
    }

    /// Sign-out: the next account on this phone may be on another team, or none.
    func forget(in defaults: UserDefaults = .standard) {
        knobs = nil
        basisByLot = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }
}

/// The baseline the per-card knobs reset to.
///
/// The sliders on the panel are deliberately per-card — a figure tuned during one
/// negotiation must not silently follow the user into the next. That alone would
/// mean nothing he tunes ever survives the card he tuned it on, so the baseline
/// itself is editable, once, here.
///
/// ON A TEAM (owner M2, 2026-10-01): when the lead has set the team's skew and
/// margin, they REPLACE this phone's on every card (`current`), and a card's sliders
/// may only go higher (`respectingTeam`), which can only lower the figure. "Average
/// of N" stays the phone's own. The team's pair arrives through
/// `MaxBuyTeamPolicy`, which is observable, so a lead's change redraws every row.
@MainActor
enum MaxBuyDefaults {
    private enum Keys {
        static let windowN = "caliper_vmb_window_n"
        static let skew = "caliper_vmb_skew"
        static let margin = "caliper_vmb_margin"
    }

    /// Memoized because the max-buy lens reads this once per card per layout pass —
    /// thousands of times a frame on a full stack — and each read is three
    /// `UserDefaults` lookups. `save` is the only writer, so it is also the only
    /// thing that has to clear it.
    private static var memo: MaxBuyPrice.Knobs?

    /// This phone's own stored baseline — what Settings → Max buy edits.
    static var phone: MaxBuyPrice.Knobs {
        if let memo { return memo }
        let knobs = load()
        memo = knobs
        return knobs
    }

    /// The baseline every card starts from: the phone's, with the team's skew and
    /// margin in place of its own when the lead has set them.
    static var current: MaxBuyPrice.Knobs { applyingTeam(phone) }

    /// The lead's pair, or nil. Read through the observable policy on purpose.
    static var team: (skew: Double, margin: Double)? {
        get { MaxBuyTeamPolicy.shared.knobs.map { ($0.skew, $0.margin) } }
        set { MaxBuyTeamPolicy.shared.knobs = newValue.map { .init(skew: $0.skew, margin: $0.margin) } }
    }

    static func applyingTeam(_ knobs: MaxBuyPrice.Knobs) -> MaxBuyPrice.Knobs {
        guard let team else { return knobs }
        return .init(windowN: knobs.windowN, skew: team.skew, margin: team.margin)
    }

    /// A card's tuned knobs, held at or above the team's: a member may make a lower
    /// offer than the lead's figure, never a higher one.
    static func respectingTeam(_ knobs: MaxBuyPrice.Knobs) -> MaxBuyPrice.Knobs {
        guard let team else { return knobs }
        return .init(windowN: knobs.windowN, skew: max(knobs.skew, team.skew), margin: max(knobs.margin, team.margin))
    }

    private static func load() -> MaxBuyPrice.Knobs {
        let defaults = UserDefaults.standard
        let standard = MaxBuyPrice.Knobs.standard
        let storedN = defaults.integer(forKey: Keys.windowN)
        return MaxBuyPrice.Knobs(
            windowN: storedN > 0 ? storedN : standard.windowN,
            // `object(forKey:)`, not `double(forKey:)`: a genuine stored 0 (skew
            // off, or no margin) is a real choice and must not read as "unset".
            skew: defaults.object(forKey: Keys.skew) as? Double ?? standard.skew,
            margin: defaults.object(forKey: Keys.margin) as? Double ?? standard.margin
        )
    }

    static func save(_ knobs: MaxBuyPrice.Knobs) {
        let defaults = UserDefaults.standard
        defaults.set(knobs.windowN, forKey: Keys.windowN)
        defaults.set(knobs.skew, forKey: Keys.skew)
        defaults.set(knobs.margin, forKey: Keys.margin)
        memo = knobs
    }

    /// One line for the Settings row: "Avg 5 · skew 30% · margin 10%" — what
    /// actually applies, the team's pair included.
    static var summary: String {
        let k = current
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        return "Avg \(k.windowN) · skew \(pct(k.skew)) · margin \(pct(k.margin))"
    }

    /// Tests only — they write the keys directly.
    static func invalidateCache() { memo = nil }

    /// Tests only. Pins the baseline for the length of `body`, then puts back exactly
    /// what was stored before — including "never set". The test host IS the app, so a
    /// bare `save` leaks twice: into whichever test runs next (a row priced on another
    /// test's margin rendered $1,082.25 beside a hero reading $934.81, 2026-09-23) and
    /// into the simulator app's real preferences. Scoped rather than paired
    /// setup/teardown because the suites are `@MainActor` and their tests synchronous,
    /// so nothing can interleave inside `body`.
    static func withPinned<T>(_ knobs: MaxBuyPrice.Knobs, _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let keys = [Keys.windowN, Keys.skew, Keys.margin]
        let stored = keys.map { defaults.object(forKey: $0) }
        let storedTeam = MaxBuyTeamPolicy.shared.knobs
        save(knobs)
        // A team policy left by another test would override the pinned knobs.
        MaxBuyTeamPolicy.shared.knobs = nil
        defer {
            // `set(nil, …)` removes the key, which restores "never set".
            for (key, value) in zip(keys, stored) { defaults.set(value, forKey: key) }
            MaxBuyTeamPolicy.shared.knobs = storedTeam
            memo = nil
        }
        return try body()
    }
}

/// Settings → Max buy. The baseline every card's sliders reset to.
///
/// Was the second half of the testing-passcode sheet until 0.9, when max buy
/// became available to everyone (owner, 2026-10-01).
struct MaxBuySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var knobs = MaxBuyDefaults.phone

    var body: some View {
        CaliperSheet(title: "Max buy") {
            Button("Close") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            defaultsForm
        } confirm: {
            EmptyView()
        }
    }

    private var defaultsForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Defaults")

            VStack(alignment: .leading, spacing: Caliper.space5) {
                Text("Every card starts from these. Adjusting the sliders on a card changes that card only.")
                    .caliperMeta()

                // The label shows what is SAVED — a 0 or blank entry is stored
                // as the standard window, so the raw field would promise a
                // number that never takes effect.
                labelled("Average of", value: "\(knobs.sanitized.windowN) sales") {
                    TextField("5", value: $knobs.windowN, format: .number)
                        .font(.price)
                        .keyboardType(.numberPad)
                        .foregroundStyle(Caliper.textPrimary)
                        .modifier(FieldBox())
                }

                if let team = MaxBuyDefaults.team {
                    // On a team whose lead set these: they apply on every card, so
                    // the phone's own would only be a number that does nothing.
                    labelled("Skew to the low end", value: percent(team.skew)) { EmptyView() }
                    labelled("Margin", value: percent(team.margin)) { EmptyView() }
                    Text("Skew and margin are set by your team lead.").caliperMeta()
                } else {
                    labelled("Skew to the low end", value: percent(knobs.skew)) {
                        MaxBuyKnobSlider(value: $knobs.skew)
                    }

                    labelled("Margin", value: percent(knobs.margin)) {
                        MaxBuyKnobSlider(value: $knobs.margin)
                    }
                }
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space4)
            .padding(.bottom, Caliper.space6)
        }
        // Saved as they move, so there is no second "did that take?" question on
        // a screen whose whole job is to be fiddled with.
        .onChange(of: knobs) { _, new in MaxBuyDefaults.save(new.sanitized) }
    }

    @ViewBuilder
    private func labelled(_ label: String, value: String,
                          @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Caliper.space3) {
            HStack {
                Text(label).caliperLabel(Caliper.textTertiary)
                Spacer()
                Text(value).caliperMeta(Caliper.textSecondary)
            }
            control()
        }
    }

    private func percent(_ v: Double) -> String {
        (v * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }
}

/// A 0–100% knob. Quiet on purpose: these live on screens that have already spent
/// their one cyan primary action, so the slider must not read as a second one.
struct MaxBuyKnobSlider: View {
    @Binding var value: Double
    /// The lowest it may go — the team's setting, for a member (owner M2).
    var floor: Double = 0

    var body: some View {
        CaliperSlider(
            value: Binding(get: { CGFloat(value) }, set: { value = max(Double($0), floor) }),
            range: CGFloat(min(floor, 0.95))...1,
            tint: Caliper.textSecondary,
            glow: false,
            unit: "%",
            fractionDigits: 0,
            step: 0.05
        )
    }
}

extension MaxBuyPrice.Knobs {
    /// Keeps a typed window and dragged proportions inside what the formula can
    /// answer for. A blank or nonsense N reads as the standard window rather than
    /// zero comps, which would look like "no data" when the truth is "bad input".
    var sanitized: Self {
        Self(
            windowN: windowN > 0 ? min(windowN, 50) : Self.standard.windowN,
            skew: min(max(skew, 0), 1),
            margin: min(max(margin, 0), 1)
        )
    }
}
