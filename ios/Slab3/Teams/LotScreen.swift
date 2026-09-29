import SwiftUI
import SwiftData

/// Every screen pushed on the Teams tab, in one switch.
struct TeamsDestination: View {
    @Bindable var app: AppState
    let route: TeamsRoute

    var body: some View {
        Group {
            switch route {
            case .lot(let id): LotScreen(app: app, lotId: id)
            case .builder(let id): LotBuilderScreen(app: app, lotId: id)
            case .activity: TeamActivityScreen(app: app)
            case .activityMembers(let lotId): ActivityMembersScreen(app: app, lotId: lotId)
            case .receipt(let lotId, let userId): MemberReceiptScreen(app: app, lotId: lotId, userId: userId)
            case .claim(let id): ClaimDetailScreen(app: app, claimId: id)
            case .members: TeamMembersSheet(team: app.team)
            case .library: BuyRangeLibrarySheet(team: app.team, lots: app.lots)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(Caliper.bg)
    }
}

/// One lot's full screen: the dashboard (bands, chart, over-limit decisions for a
/// lead), a lead's Edit / Close in the header menu (D12), and "Scan into" while it
/// is open. Reached from a lot's title on Teams, the chevron on an open-lot row, or
/// the Cards lot line.
struct LotScreen: View {
    @Bindable var app: AppState
    let lotId: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var confirmStatus: LotStatus?
    @State private var error: String?

    private var lot: Lot? { app.lots.lots.first { $0.id == lotId } }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(context: lot.map(LotText.statusLine) ?? "", title: lot?.name ?? "Lot") {
                if app.team.isLead, let lot { leadMenu(lot) }
                Button("Done") { dismiss() }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
                    .frame(minHeight: Caliper.hitMin)
            }
            if let lot {
                ScrollView {
                    LotDashboardView(lot: lot, lots: app.lots, team: app.team)
                        .padding(.horizontal, Caliper.gutter)
                        .padding(.bottom, Caliper.space8)
                }
                if lot.status == .active {
                    VStack(spacing: 0) {
                        Hairline()
                        CaliperButton(title: "Scan into \(lot.name)", variant: .primary, icon: "barcode.viewfinder",
                                      fullWidth: true) { app.scanInto(lot, in: context) }
                            .padding(.horizontal, Caliper.gutter)
                            .padding(.vertical, Caliper.space5)
                    }
                }
            } else {
                Text("This lot is gone — a lead deleted it.")
                    .font(.calBody)
                    .foregroundStyle(Caliper.textSecondary)
                    .padding(Caliper.gutter)
                Spacer()
            }
        }
        .confirmationDialog(confirmStatus == .closed ? "Close this lot?" : "Reopen this lot?",
                            isPresented: Binding(get: { confirmStatus != nil }, set: { if !$0 { confirmStatus = nil } }),
                            titleVisibility: .visible) {
            if let status = confirmStatus, let lot {
                Button(status == .closed ? "Close lot" : "Reopen lot", role: status == .closed ? .destructive : nil) {
                    Task { error = await setStatus(status, of: lot) }
                }
            }
        } message: {
            Text(confirmStatus == .closed
                 ? "Buyers stop filing into it. Everything already bought stays, and you can reopen it."
                 : "Buyers can file into it again.")
        }
        .alert("Lot", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private func leadMenu(_ lot: Lot) -> some View {
        Menu {
            Button { app.teamsPath.append(.builder(lot.id)) } label: { Label("Edit lot", systemImage: "pencil") }
            if lot.status == .active {
                Button(role: .destructive) { confirmStatus = .closed } label: { Label("Close lot", systemImage: "lock") }
            } else if lot.status == .closed {
                Button { confirmStatus = .active } label: { Label("Reopen lot", systemImage: "lock.open") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Caliper.textSecondary)
                .frame(width: Caliper.hitMin, height: Caliper.hitMin)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Lot actions")
    }

    private func setStatus(_ status: LotStatus, of lot: Lot) async -> String? {
        guard let teamId = app.team.team?.id else { return TeamError.copy(for: "not_member") }
        return await app.lots.updateLot(lot.id, name: lot.name, deadline: lot.deadline, banner: lot.banner,
                                        status: status, teamId: teamId)
    }
}
