import SwiftUI

/// The passcode gate for the Verified Max Buy Price pilot (2026-09-16, owner
/// decision: ship it to one user while the weights are uncalibrated).
///
/// THIS IS OBFUSCATION, NOT SECURITY, and it is meant to be. The passcode ships in
/// the binary as plain text and anyone who looks at the app can read it. Its job is
/// to stop a curious TestFlight user stumbling into an uncalibrated buy
/// recommendation and acting on it — not to withstand anyone who is trying. A real
/// entitlement would mean an Edge Function deploy, which reaches every user at once
/// and is a production release; that is not warranted to hide one panel.
enum TestingGate {

    /// CHANGE THIS to whatever you give the tester. There is nowhere else it lives.
    static let passcode = "letscook"

    /// Single-screen preference, the `caliper_auto_scan` idiom: only the detail
    /// screen and this sheet read it, so it is deliberately not in AppState.
    static let unlockedKey = "caliper_testing_unlocked"

    static func accepts(_ entry: String) -> Bool {
        entry.trimmingCharacters(in: .whitespacesAndNewlines) == passcode
    }
}

/// The baseline the per-card knobs reset to.
///
/// The sliders on the panel are deliberately per-card — a figure tuned during one
/// negotiation must not silently follow the tester into the next. That alone would
/// mean nothing he tunes ever survives the card he tuned it on, so the baseline
/// itself is editable, once, here.
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

    static var current: MaxBuyPrice.Knobs {
        if let memo { return memo }
        let knobs = load()
        memo = knobs
        return knobs
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
        save(knobs)
        defer {
            // `set(nil, …)` removes the key, which restores "never set".
            for (key, value) in zip(keys, stored) { defaults.set(value, forKey: key) }
            memo = nil
        }
        return try body()
    }
}

/// Settings → About → Testing. Locked, it asks for the passcode; unlocked, it
/// shows the baseline the panel's knobs reset to, and the way back out.
struct TestingGateSheet: View {
    @AppStorage(TestingGate.unlockedKey) private var unlocked = false
    @Environment(\.dismiss) private var dismiss

    @State private var entry = ""
    @State private var error: String?
    @State private var knobs = MaxBuyDefaults.current

    var body: some View {
        CaliperSheet(title: unlocked ? "Testing version" : "Testing passcode") {
            Button(unlocked ? "Close" : "Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            if unlocked { defaultsForm } else { passcodeForm }
        } confirm: {
            if unlocked {
                CaliperButton(title: "Turn off testing version", variant: .danger, fullWidth: true) {
                    unlocked = false
                    entry = ""
                    dismiss()
                }
            } else {
                CaliperButton(title: "Unlock", variant: .primary, fullWidth: true,
                              disabled: entry.isEmpty) {
                    submit()
                }
            }
        }
    }

    private var passcodeForm: some View {
        VStack(alignment: .leading, spacing: Caliper.space5) {
            SecureField("Passcode", text: $entry)
                .font(.calBody)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(Caliper.textPrimary)
                .modifier(FieldBox())
                .onSubmit(submit)

            if let error {
                Text(error).caliperMeta(Caliper.confLow)
            }

            Text("Turns on features that are still being tested. Prices they suggest are not final and have not been checked against real sales.")
                .caliperMeta()
        }
        .padding(.horizontal, Caliper.gutter)
        .padding(.top, Caliper.space6)
    }

    private var defaultsForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Max buy defaults")

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

                labelled("Skew to the low end", value: percent(knobs.skew)) {
                    MaxBuyKnobSlider(value: $knobs.skew)
                }

                labelled("Margin", value: percent(knobs.margin)) {
                    MaxBuyKnobSlider(value: $knobs.margin)
                }
            }
            .padding(.horizontal, Caliper.gutter)
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

    private func submit() {
        guard TestingGate.accepts(entry) else {
            error = "That passcode isn\u{2019}t right."
            return
        }
        error = nil
        unlocked = true
        entry = ""
    }
}

/// A 0–100% knob. Quiet on purpose: these live on screens that have already spent
/// their one cyan primary action, so the slider must not read as a second one.
struct MaxBuyKnobSlider: View {
    @Binding var value: Double

    var body: some View {
        CaliperSlider(
            value: Binding(get: { CGFloat(value) }, set: { value = Double($0) }),
            range: 0...1,
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
