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
    @State private var showMaxBuy = false
    /// Re-read when the sheet closes: `MaxBuyDefaults` is a memo, not observable.
    @State private var maxBuySummary = MaxBuyDefaults.summary
    @State private var showTeamOnboard = false
    @State private var showLinkCode = false
    @State private var showMyCards = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(context: "\(cards.count) cards", title: "Settings")
            ScrollView {
                VStack(spacing: 0) {
                    if TeamsFeature.isAvailable { teamSection; consignSection }
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
                    if app.team.team == nil {
                        Hairline()
                        row("Buy ranges", value: "Not available")
                    }

                    // Our own figure, available to everyone since 0.9 (owner,
                    // 2026-10-01). Every card's sliders reset to these.
                    SectionLabel(text: "Max buy")
                    row("Defaults", value: maxBuySummary) { showMaxBuy = true }

                    SectionLabel(text: "CSV")
                    row("Default columns", value: "\(app.enabledColumns.count) selected")
                    Hairline()
                    row("Filename pattern", value: "INVENTORY_GROUP_DATE")

                    SectionLabel(text: "About")
                    row("How it works", value: "Replay") { showOnboarding = true }
                    Hairline()
                    row("Version", value: Self.version)
                    #if DEBUG
                    Hairline()
                    // Debug builds only: which Supabase this build is talking to.
                    row("Server", value: Backend.serverLabel,
                        dot: Backend.isLocal ? Caliper.confMid : nil,
                        valueTint: Backend.isLocal ? Caliper.confMid : nil)
                    #endif
                    Hairline()
                    Button {
                        // The next person to sign in on this phone may be on no team.
                        app.onTeamHint = false
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
        .sheet(isPresented: $showMaxBuy, onDismiss: { maxBuySummary = MaxBuyDefaults.summary }) {
            MaxBuySettingsSheet()
        }
        .sheet(isPresented: $showTeamOnboard) {
            // Joined or created: straight to the new Teams tab (D28), where the
            // one-time intro card explains the flow.
            TeamOnboardSheet(team: app.team) { app.tabTouched = true; app.tab = .teams }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showLinkCode) { LinkCodeSheet(team: app.team) }
        .sheet(isPresented: $showMyCards) { MyCardsSheet(team: app.team).presentationDetents([.large]) }
        // Which teams this account consigns to — one small request per Settings
        // visit, never at launch, and only where Teams may run at all.
        .task { if TeamsFeature.isAvailable { await app.team.loadLinks() } }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingScreen { showOnboarding = false }
        }
    }

    /// Read from the bundle, never typed. This row said "0.1" through 0.3 and 0.4
    /// because the literal was never touched when project.yml was bumped — and the
    /// one person who needs it is a tester reporting which build they saw a bug on.
    /// Shows both, because TestFlight identifies a build by the number in brackets.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    private var lastRefresh: String {
        guard let last = cards.compactMap(\.lastPricedAt).max() else { return "Never" }
        return last.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Settings → Team. Everything about the team lives on the Teams tab now
    /// (teams-first plan); Settings keeps the door in — "Join or create a team" —
    /// and, for a member, one row that goes there. Present only when
    /// TeamsFeature.isAvailable; nothing renders until the first load answers, so a
    /// member never sees "Join or create" flash past.
    @ViewBuilder
    private var teamSection: some View {
        if let team = app.team.team {
            SectionLabel(text: "Team")
            row("Team", value: team.name, verbatim: true) { app.tabTouched = true; app.tab = .teams }
        } else if app.team.loaded, app.team.lastLoadOK {
            // Only once the server has SAID "no team": a member opening the app with
            // no signal must not be offered to join a team they are already on.
            SectionLabel(text: "Team")
            row("Join or create a team", value: "") { showTeamOnboard = true }
        }
    }

    /// Settings → Consigning (V5, 2026-10-04). Someone whose cards a lead tracks
    /// links an account with the lead's code, then sees those cards here, read-only.
    /// Not team membership: it works on no team, or on a team of one's own.
    @ViewBuilder
    private var consignSection: some View {
        SectionLabel(text: "Consigning")
        if !app.team.links.isEmpty {
            row("My cards", value: app.team.links.map(\.teamName).joined(separator: ", "), verbatim: true) {
                showMyCards = true
            }
            Hairline()
        }
        row("Link to a team", value: "Code") { showLinkCode = true }
    }

    @ViewBuilder
    private func row(_ label: String, value: String, dot: Color? = nil,
                     valueTint: Color? = nil, verbatim: Bool = false,
                     tap: (() -> Void)? = nil) -> some View {
        Button {
            tap?()
        } label: {
            HStack(spacing: Caliper.space5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(label).font(.calBody).foregroundStyle(Caliper.textPrimary)
                Spacer(minLength: Caliper.space4)
                if verbatim {
                    Text(value).font(.calBody).foregroundStyle(Caliper.textSecondary).lineLimit(1)
                } else {
                    Text(value).caliperLabel(valueTint ?? (tap == nil ? Caliper.textTertiary : Caliper.textSecondary))
                }
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
