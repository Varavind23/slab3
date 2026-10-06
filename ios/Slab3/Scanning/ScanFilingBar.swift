import SwiftUI
import SwiftData

/// Scan's filing bar (teams plan §7.1): which group new scans go into.
///
/// WHY IT EXISTS FOR EVERYONE, not only teams (owner decision, 2026-09-24): a
/// sourcer working one buyer's stack wants every slab to land in that buyer's group
/// without selecting them all afterwards. For a team it is also how a buyer says
/// which LOT they are buying into — one at a time, switchable (plan §4d).
///
/// Default is none, which is exactly the Scan tab as it was: scans go to inventory
/// ungrouped. The bar is the `FilterPill` shape on purpose — the same "this is the
/// scope you are working in" control, one tab over.
struct ScanFilingBar: View {
    let target: Folder?
    /// Set when the target is a team lot: every scan is then a claim.
    var lot: Lot? = nil
    /// Cards scanned today that are in the target group.
    let filedToday: Int
    /// A CL lot claims on Card Ladder's value — without a connection nothing can be
    /// claimed, and the bar must say so rather than let scans quietly go nowhere.
    /// A CY lot never sets it: members without Card Ladder buy into one (M3).
    var needsCardLadder = false
    let tap: () -> Void
    /// Filing into a lot: the ⇄ at the bar's end opens the plain-group picker, the
    /// way out of a lot without closing it (D29). Tapping the rest goes to Teams.
    var swap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            main
            if lot != nil, let swap {
                Rectangle().fill(Caliper.lineStrong).frame(width: Caliper.borderWidth, height: Caliper.hitMin)
                Button(action: swap) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Caliper.textSecondary)
                        .frame(width: Caliper.hitMin, height: Caliper.hitMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CaliperPressStyle())
                .accessibilityLabel("Stop filing into \(target?.name ?? "this lot")")
                .accessibilityHint("Choose None or a group instead")
            }
        }
        .frame(height: Caliper.hitMin)
        .overlay(Rectangle().strokeBorder(needsCardLadder ? Caliper.confMid.opacity(0.6) : Caliper.lineStrong,
                                          lineWidth: Caliper.borderWidth))
    }

    private var main: some View {
        Button(action: tap) {
            HStack(spacing: Caliper.space4) {
                if let target, needsCardLadder {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Caliper.confMid)
                    Text("Connect Card Ladder to buy into \(target.name)")
                        .font(.calBody)
                        .foregroundStyle(Caliper.confMid)
                        .lineLimit(1)
                    Spacer(minLength: Caliper.space4)
                } else if let target {
                    Circle().fill(target.hue).frame(width: 8, height: 8)
                    if lot != nil { Text("Lot").caliperLabel(Caliper.textSecondary) }
                    Text(target.name)
                        .font(.calBody)
                        .foregroundStyle(Caliper.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Caliper.space4)
                    if let deadline = lot?.deadline {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(LotDashboard.countdown(to: deadline, now: context.date)
                                    .map { String($0.dropLast(3)) } ?? "Past deadline")
                                .caliperLabel(Caliper.textSecondary)
                        }
                    }
                    Text("\(filedToday) today").caliperLabel(Caliper.textSecondary)
                } else {
                    Image(systemName: "tray")
                        .font(.system(size: 12))
                        .foregroundStyle(Caliper.textTertiary)
                    Text("Not filing · scans go to inventory")
                        .font(.calBody)
                        .foregroundStyle(Caliper.textTertiary)
                        .lineLimit(1)
                    Spacer(minLength: Caliper.space4)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Caliper.textTertiary)
            }
            .padding(.horizontal, Caliper.rowPad)
            .frame(height: Caliper.hitMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .accessibilityLabel(target.map { "Filing scans into \($0.name)" } ?? "Not filing scans into a group")
        .accessibilityHint(lot != nil ? "Opens the lot on the Teams tab" : "Choose the group new scans go into")
    }
}

/// Pick where scans go. The Group sheet's shell (Caliper §4) — the same rows, the
/// same inline create — with a `None` row first, because "stop filing" has to be
/// one tap, not a hunt for how to clear it.
struct ScanTargetSheet: View {
    @Binding var targetId: String
    @Binding var explicitNone: Bool
    /// On a team: a row that sends the user to Teams, where lots are chosen
    /// (teams-first plan, D8). Lots are never picked here.
    var openTeams: (() -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Folder.createdAt, order: .reverse) private var allGroups: [Folder]
    @State private var newName = ""

    private var groups: [Folder] { allGroups.filter { !$0.archived && !$0.isTeamLot } }
    private var trimmed: String { newName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        CaliperSheet(title: "File scans into") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            SheetRow(label: "None", sub: "Scans go to inventory ungrouped", active: targetId.isEmpty) {
                choose(nil)
            }
            Hairline()
            if let openTeams {
                SheetRow(label: "A team lot", sub: "Lots are picked on the Teams tab", trailing: "Teams ›") {
                    openTeams()
                }
                Hairline()
                SectionLabel(text: "Groups")
            }
            ForEach(groups) { group in
                SheetRow(
                    label: group.name,
                    sub: "\(group.cards.count) cards",
                    active: targetId == group.localId.uuidString,
                    leading: { Circle().fill(group.hue).frame(width: 8, height: 8) }
                ) { choose(group) }
                Hairline()
            }
        } confirm: {
            VStack(spacing: Caliper.space5) {
                Hairline(color: Caliper.cyanDim)
                HStack(spacing: Caliper.space4) {
                    TextField("New group name...", text: $newName)
                        .font(.calBody)
                        .foregroundStyle(Caliper.textPrimary)
                        .padding(.horizontal, Caliper.rowPad)
                        .frame(height: Caliper.hitMin)
                        .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                    CaliperButton(title: "Create", variant: .primary, disabled: trimmed.isEmpty) {
                        let group = Folder(name: trimmed, hueIndex: allGroups.count % Caliper.groupHues.count)
                        context.insert(group)
                        try? context.save()
                        choose(group)
                    }
                }
            }
        }
    }

    private func choose(_ group: Folder?) {
        targetId = group?.localId.uuidString ?? ""
        explicitNone = group == nil
        dismiss()
    }
}
