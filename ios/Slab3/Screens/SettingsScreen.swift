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
    @State private var showTesting = false
    @AppStorage(TestingGate.unlockedKey) private var testingUnlocked = false
    @State private var showTeamOnboard = false
    @State private var showMembers = false
    @State private var showDisplayName = false
    @State private var confirmRotate = false
    @State private var teamError: String?
    @State private var showLibrary = false
    @State private var showLots = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(context: "\(cards.count) cards", title: "Settings")
            ScrollView {
                VStack(spacing: 0) {
                    if TeamsFeature.isAvailable { teamSection }
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
                    // Green so the state is unmistakable: an uncalibrated buy
                    // recommendation is showing on every card, and that should
                    // never be something you have to go and check.
                    if testingUnlocked {
                        row("Testing version", value: "On",
                            dot: Caliper.payout, valueTint: Caliper.payout) { showTesting = true }
                    } else {
                        row("Testing", value: "Off") { showTesting = true }
                    }
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
        .sheet(isPresented: $showTesting) { TestingGateSheet() }
        .sheet(isPresented: $showTeamOnboard) { TeamOnboardSheet(team: app.team).presentationDetents([.large]) }
        .sheet(isPresented: $showMembers) { TeamMembersSheet(team: app.team).presentationDetents([.large]) }
        .sheet(isPresented: $showDisplayName) {
            TeamDisplayNameSheet(team: app.team).presentationDetents([.height(260)])
        }
        .sheet(isPresented: $showLibrary) {
            BuyRangeLibrarySheet(team: app.team, lots: app.lots).presentationDetents([.large])
        }
        .sheet(isPresented: $showLots) {
            LotListSheet(team: app.team, lots: app.lots).presentationDetents([.large])
        }
        .confirmationDialog("Rotate the team code?", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("Rotate code") { Task { teamError = await app.team.rotateCode() } }
        } message: {
            Text("The old code stops working. Everyone already on the team stays on it.")
        }
        .alert("Team", isPresented: Binding(get: { teamError != nil }, set: { if !$0 { teamError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(teamError ?? "")
        }
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

    /// Settings → Team (plan §7.7). Present only when TeamsFeature.isAvailable; a
    /// user who is on no team sees one row and nothing else. Nothing renders until
    /// the first load answers, so a member never sees "Join or create" flash past.
    @ViewBuilder
    private var teamSection: some View {
        let store = app.team
        if let team = store.team {
            SectionLabel(text: "Team")
            // A team name is rendered verbatim, like a group's — never upper-cased
            // into a label.
            row("Team", value: team.name, verbatim: true)
            Hairline()
            row("Members", value: "\(store.members.count)") { showMembers = true }
            Hairline()
            // Buyers see the code too (they can already read it under RLS, and
            // passing it on at the table is how a team grows); only a lead rotates it.
            row("Team code", value: JoinCode.display(team.joinCode),
                tap: store.isLead ? { confirmRotate = true } : nil)
            Hairline()
            row("Your name", value: store.me?.displayName ?? "\u{2014}", verbatim: true) { showDisplayName = true }
            Hairline()
            row("Lots", value: lotsValue) { showLots = true }
            Hairline()
            // Replaces Payout's "Buy ranges · Not available" placeholder for team
            // members: a buy range belongs to the team, not to a payout.
            row("Buy ranges", value: "\(app.lots.library.count) saved") { showLibrary = true }
        } else if store.loaded {
            SectionLabel(text: "Team")
            row("Join or create a team", value: "") { showTeamOnboard = true }
        }
    }

    private var lotsValue: String {
        let open = app.lots.lots.filter { $0.status == .active }.count
        return open == 1 ? "1 open" : "\(open) open"
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
