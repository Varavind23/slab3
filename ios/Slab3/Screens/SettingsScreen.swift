import SwiftUI
import SwiftData

/// Settings, now a tab rather than a hamburger sheet (README.md §7). The client's
/// reference never showed this screen, so the sections are derived from what the
/// rest of the product implies — treat them as a proposal.
///
/// Rows whose backing work doesn't exist yet say so in their value ("Not set",
/// "No source") instead of showing a plausible default. A settings screen that
/// lies about what's configured is worse than one that admits a gap.
struct SettingsScreen: View {
    @Bindable var app: AppState
    let auth: AuthManager
    @Environment(\.modelContext) private var context
    @Query private var cards: [Card]

    @AppStorage(PriceService.connectedKey) private var cardLadderConnected = false
    @State private var showConnect = false
    @State private var showPayout = false
    @State private var showOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(context: "\(cards.count) cards", title: "Settings")
            ScrollView {
                VStack(spacing: 0) {
                    SectionLabel(text: "Price sources")
                    row("Card Ladder", value: cardLadderConnected ? "Connected" : "Not connected",
                        dot: Caliper.srcCL) { showConnect = true }
                    Hairline()
                    row("Courtyard", value: "Public search", dot: Caliper.srcCY)
                    Hairline()
                    row("Default emphasis", value: app.activeSource.accessibilityName) {
                        app.activeSource = PriceSource.allCases[
                            (PriceSource.allCases.firstIndex(of: app.activeSource)! + 1) % PriceSource.allCases.count
                        ]
                    }

                    SectionLabel(text: "Price refresh")
                    row("Automatic refresh", value: "On scan")
                    Hairline()
                    row("Last full refresh", value: lastRefresh)

                    SectionLabel(text: "Payout")
                    row("Default payout %", value: app.payoutPercent.map {
                        $0.formatted(.number.precision(.fractionLength(1))) + "%"
                    } ?? "Not set") { showPayout = true }
                    Hairline()
                    row("Payout provider", value: "Not set")
                    Hairline()
                    row("Buy ranges", value: "Not available")

                    SectionLabel(text: "CSV")
                    row("Default columns", value: "\(app.enabledColumns.count) selected")
                    Hairline()
                    row("Filename pattern", value: "INVENTORY_GROUP_DATE")

                    SectionLabel(text: "About")
                    row("How it works", value: "Replay") { showOnboarding = true }
                    Hairline()
                    row("Version", value: "0.1")
                    Hairline()
                    Button {
                        Task { await auth.signOut() }
                    } label: {
                        HStack {
                            Text("Sign out").font(.calBody).foregroundStyle(Caliper.danger)
                            Spacer()
                        }
                        .padding(.horizontal, Caliper.gutter)
                        .frame(height: Caliper.hitMin)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CaliperPressStyle())

                    if case let .signedIn(_, email) = auth.state, let email {
                        Text(email)
                            .caliperMeta(Caliper.textTertiary)
                            .padding(.horizontal, Caliper.gutter)
                            .padding(.top, Caliper.space4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, Caliper.space8)
            }
        }
        .background(Caliper.bg)
        .sheet(isPresented: $showConnect) { CardLadderConnectView() }
        .sheet(isPresented: $showPayout) { PayoutSheet(app: app).presentationDetents([.height(260)]) }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingScreen { showOnboarding = false }
        }
    }

    private var lastRefresh: String {
        guard let last = cards.compactMap(\.lastPricedAt).max() else { return "Never" }
        return last.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    @ViewBuilder
    private func row(_ label: String, value: String, dot: Color? = nil, tap: (() -> Void)? = nil) -> some View {
        Button {
            tap?()
        } label: {
            HStack(spacing: Caliper.space5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(label).font(.calBody).foregroundStyle(Caliper.textPrimary)
                Spacer(minLength: Caliper.space4)
                Text(value).caliperLabel(tap == nil ? Caliper.textTertiary : Caliper.textSecondary)
                if tap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Caliper.textTertiary)
                }
            }
            .padding(.horizontal, Caliper.gutter)
            .frame(height: Caliper.hitMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .disabled(tap == nil)
    }
}

/// The payout rate has to come from somewhere, and the design never says where
/// (README.md open question 4). Until it does, the user sets it — and until they
/// do, every payout figure honestly reads as an em dash.
struct PayoutSheet: View {
    @Bindable var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        CaliperSheet(title: "Default payout %") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: Caliper.space5) {
                TextField("e.g. 12.6", text: $text)
                    .font(.price)
                    .keyboardType(.decimalPad)
                    .foregroundStyle(Caliper.textPrimary)
                    .padding(.horizontal, Caliper.rowPad)
                    .frame(height: Caliper.hitMin)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                Text("The share of a card's value your outlet pays out. Every Est. payout figure reads an em dash until this is set.")
                    .caliperMeta()
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space6)
        } confirm: {
            CaliperButton(title: "Save", variant: .primary, fullWidth: true, disabled: Double(text) == nil) {
                app.payoutPercent = Double(text)
                dismiss()
            }
        }
        .onAppear { text = app.payoutPercent.map { String($0) } ?? "" }
    }
}
