import SwiftUI

// Settings → Team (plan §7.7). Joining is by code, never by invitation (owner
// decision): the lead reads a six-character code across the table and the buyer
// types it. No email, no link, no approval step. Being on a team is what turns
// every other team feature on, so this is the only door.

/// Join an existing team by code, or start one. One sheet, two modes — starting a
/// team is the rarer path (one lead, many buyers), so joining is what it opens on.
struct TeamOnboardSheet: View {
    let team: TeamStore
    /// Called once the user is on the team — Settings takes them to Teams.
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    enum Mode { case join, create }
    @State private var mode: Mode = .join
    @State private var code = ""
    @State private var teamName = ""
    @State private var displayName = ""
    @State private var error: String?

    var body: some View {
        CaliperSheet(title: mode == .join ? "Join a team" : "Start a team") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if mode == .join {
                    SectionLabel(text: "Team code")
                    field("K7Q-2MX", text: $code, mono: true)
                        .textInputAutocapitalization(.characters)
                    Text("Your lead finds it on the Teams tab.")
                        .caliperMeta()
                        .padding(.horizontal, Caliper.gutter)
                        .padding(.top, Caliper.space4)
                } else {
                    SectionLabel(text: "Team name")
                    field("Buyers", text: $teamName)
                }
                SectionLabel(text: "Your name")
                field("What teammates see on your buys", text: $displayName)

                if let error {
                    Text(error)
                        .caliperMeta(Caliper.confMid)
                        .padding(.horizontal, Caliper.gutter)
                        .padding(.top, Caliper.space5)
                }

                Button {
                    mode = mode == .join ? .create : .join
                    error = nil
                } label: {
                    Text(mode == .join ? "Starting a team? Create one" : "Have a code? Join instead")
                        .caliperLabel(Caliper.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Caliper.gutter)
                        .frame(minHeight: Caliper.hitMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CaliperPressStyle())
                .padding(.top, Caliper.space6)
            }
        } confirm: {
            CaliperButton(title: mode == .join ? "Join team" : "Create team",
                          variant: .primary, fullWidth: true,
                          disabled: !canSubmit || team.isWorking) {
                Task { await submit() }
            }
        }
    }

    private var trimmedName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool {
        guard !trimmedName.isEmpty else { return false }
        switch mode {
        case .join: return JoinCode.isComplete(code)
        case .create: return !teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func submit() async {
        error = nil
        let failure = switch mode {
        case .join: await team.join(code: code, displayName: trimmedName)
        case .create: await team.create(name: teamName.trimmingCharacters(in: .whitespacesAndNewlines),
                                        displayName: trimmedName)
        }
        if let failure { error = failure } else { dismiss(); onDone() }
    }

    private func field(_ prompt: String, text: Binding<String>, mono: Bool = false) -> some View {
        TextField(prompt, text: text)
            .font(mono ? .price : .calBody)
            .autocorrectionDisabled()
            .foregroundStyle(Caliper.textPrimary)
            .padding(.horizontal, Caliper.rowPad)
            .frame(height: Caliper.hitMin)
            .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
            .padding(.horizontal, Caliper.gutter)
    }
}

/// Everyone on the team. Delegation is a long press — the SYSTEM context menu,
/// for the same reason the Cards row uses it (CLAUDE.md, 2026-09-16): it brings
/// Apple's zoom and haptic. Two taps to make someone lead, no approval step
/// (teams.md §11).
///
/// Below them, the lead's VIRTUAL members (V1–V6, 2026-10-04): consignors and anyone
/// else whose slabs the lead tracks, with or without the app. They are not on the
/// team — a linked one sees only the slabs credited to them.
struct TeamMembersSheet: View {
    let team: TeamStore
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmLeave = false
    @State private var adding = false
    @State private var openPerson: TeamPerson?

    /// Roster entries that are not team members: virtual, or linked consignors.
    private var others: [TeamPerson] {
        let memberIds = Set(team.members.map(\.userId))
        return team.people.filter { $0.userId.map { !memberIds.contains($0) } ?? true }
    }

    var body: some View {
        CaliperSheet(title: "Members · \(team.members.count)") {
            Button("Done") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(spacing: 0) {
                ForEach(team.members) { member in
                    row(member)
                    Hairline()
                }
                if team.isLead || !others.isEmpty {
                    SectionLabel(text: "Virtual members · \(others.count)")
                    Hairline()
                    ForEach(others) { person in
                        personRow(person)
                        Hairline()
                    }
                    if team.isLead {
                        SheetRow(label: "Add a virtual member", sub: "Someone whose cards you track — no app needed",
                                 trailing: "+") { adding = true }
                        Hairline()
                    }
                }
                if let error {
                    Text(error)
                        .caliperMeta(Caliper.confMid)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Caliper.gutter)
                        .padding(.top, Caliper.space5)
                }
                if team.isLead && team.members.count > 1 {
                    Text("Press and hold a member to make them lead or remove them.")
                        .caliperMeta()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Caliper.gutter)
                        .padding(.top, Caliper.space5)
                }
            }
        } confirm: {
            // Leaving is the destructive act here, so it is the only red thing.
            CaliperButton(title: "Leave team", variant: .danger, fullWidth: true,
                          disabled: team.isWorking) { confirmLeave = true }
        }
        .confirmationDialog("Leave \(team.team?.name ?? "the team")?", isPresented: $confirmLeave,
                            titleVisibility: .visible) {
            Button("Leave team", role: .destructive) {
                Task {
                    guard let me = team.me else { return }
                    if let failure = await team.remove(me) { error = failure } else { dismiss() }
                }
            }
        } message: {
            Text(team.members.count == 1
                 ? "You're the only member, so the team and its lots are deleted."
                 : "Your buys stay in the team's lots. You'll need the code to come back.")
        }
        .sheet(isPresented: $adding) { PersonEditSheet(team: team, person: nil) }
        .sheet(item: $openPerson) { PersonSheet(team: team, personId: $0.id) }
    }

    @ViewBuilder
    private func personRow(_ person: TeamPerson) -> some View {
        Button { if team.isLead { openPerson = person } } label: {
            HStack(spacing: Caliper.space5) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.displayName).font(.calBody).foregroundStyle(Caliper.textPrimary)
                    if let note = person.note { Text(note).caliperMeta(Caliper.textTertiary).lineLimit(1) }
                }
                Spacer(minLength: Caliper.space4)
                Text(person.isVirtual ? (person.linkCodeAt == nil ? "Virtual" : "Invited") : "Linked")
                    .caliperLabel(person.isVirtual ? Caliper.textTertiary : Caliper.textPrimary)
                if team.isLead {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Caliper.textTertiary)
                }
            }
            .padding(.horizontal, Caliper.gutter)
            .frame(minHeight: Caliper.hitMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .disabled(!team.isLead)
    }

    @ViewBuilder
    private func row(_ member: TeamStore.Member) -> some View {
        let isMe = member.userId == team.myUserId
        HStack(spacing: Caliper.space5) {
            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName).font(.calBody).foregroundStyle(Caliper.textPrimary)
                if isMe { Text("You").caliperMeta(Caliper.textTertiary) }
            }
            Spacer(minLength: Caliper.space4)
            Text(member.role == .lead ? "Lead" : "Buyer")
                .caliperLabel(member.role == .lead ? Caliper.textPrimary : Caliper.textTertiary)
        }
        .padding(.horizontal, Caliper.gutter)
        .frame(minHeight: Caliper.hitMin)
        .contentShape(Rectangle())
        .contextMenu {
            if team.isLead && !isMe {
                if member.role == .buyer {
                    Button { act { await team.setRole(.lead, for: member) } } label: {
                        Label("Make lead", systemImage: "person.badge.key")
                    }
                } else {
                    Button { act { await team.setRole(.buyer, for: member) } } label: {
                        Label("Make buyer", systemImage: "person")
                    }
                }
                Button(role: .destructive) { act { await team.remove(member) } } label: {
                    Label("Remove from team", systemImage: "person.badge.minus")
                }
            } else if team.isLead && isMe && team.leads.count > 1 {
                Button { act { await team.setRole(.buyer, for: member) } } label: {
                    Label("Step down to buyer", systemImage: "person")
                }
            }
        }
    }

    private func act(_ work: @escaping () async -> String?) {
        error = nil
        Task { error = await work() }
    }
}

/// Edit the name teammates see on your buys.
struct TeamDisplayNameSheet: View {
    let team: TeamStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        CaliperSheet(title: "Your name") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: Caliper.space5) {
                TextField("Name", text: $name)
                    .font(.calBody)
                    .autocorrectionDisabled()
                    .foregroundStyle(Caliper.textPrimary)
                    .padding(.horizontal, Caliper.rowPad)
                    .frame(height: Caliper.hitMin)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                Text(error ?? "Shown on every card you buy into a lot, and on a limit block.")
                    .caliperMeta(error == nil ? Caliper.textSecondary : Caliper.confMid)
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space6)
        } confirm: {
            CaliperButton(title: "Save", variant: .primary, fullWidth: true,
                          disabled: trimmed.isEmpty || trimmed == team.me?.displayName || team.isWorking) {
                Task {
                    if let failure = await team.setDisplayName(trimmed) { error = failure } else { dismiss() }
                }
            }
        }
        .onAppear { name = team.me?.displayName ?? "" }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The lead sets the team's max-buy skew and margin (owner M2, 2026-10-01).
///
/// Set, they REPLACE every member's own skew and margin, on every card, while they
/// are on the team (owner, Q2) — so the max buy a member holds out to a seller is
/// the lead's number. A member may still drag a card's sliders HIGHER for a lower
/// offer, never lower: a higher skew or margin can only lower the figure
/// (MaxBuyPrice's algebra), so "at least the lead's knobs" is "at most the lead's
/// figure". "Average of N" stays each phone's own (owner, Q4).
struct TeamMaxBuySheet: View {
    let team: TeamStore
    @Environment(\.dismiss) private var dismiss

    @State private var skew: Double
    @State private var margin: Double
    @State private var error: String?

    init(team: TeamStore) {
        self.team = team
        let set = team.team?.maxBuy
        let phone = MaxBuyPrice.Knobs.standard
        _skew = State(initialValue: set?.skew ?? phone.skew)
        _margin = State(initialValue: set?.margin ?? phone.margin)
    }

    /// The Teams row's value: "skew 40% · margin 12%", or whose settings apply.
    static func summary(_ team: TeamStore.Team?) -> String {
        guard let set = team?.maxBuy else { return "Each member's own" }
        return "skew \(percent(set.skew)) · margin \(percent(set.margin))"
    }

    private static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    var body: some View {
        CaliperSheet(title: "Team max buy") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: Caliper.space5) {
                Text("Every member's max buy uses these, on every card. A member can lower a card's figure during a negotiation, never raise it past yours.")
                    .caliperMeta()
                labelled("Skew to the low end", value: Self.percent(skew)) { MaxBuyKnobSlider(value: $skew) }
                labelled("Margin", value: Self.percent(margin)) { MaxBuyKnobSlider(value: $margin) }
                if team.team?.maxBuy != nil {
                    Button("Clear — members use their own") { Task { await save(nil, nil) } }
                        .font(.mono(10, .medium))
                        .foregroundStyle(Caliper.textSecondary)
                        .frame(minHeight: Caliper.hitMin)
                }
                if let error { Text(error).caliperMeta(Caliper.confLow) }
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space6)
        } confirm: {
            CaliperButton(title: "Save for the team", variant: .primary, fullWidth: true,
                          disabled: team.isWorking) {
                Task { await save(skew, margin) }
            }
        }
    }

    @ViewBuilder
    private func labelled(_ label: String, value: String, @ViewBuilder control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Caliper.space3) {
            HStack {
                Text(label).caliperLabel(Caliper.textTertiary)
                Spacer()
                Text(value).caliperMeta(Caliper.textSecondary)
            }
            control()
        }
    }

    private func save(_ skew: Double?, _ margin: Double?) async {
        if let failure = await team.setMaxBuy(skew: skew, margin: margin) { error = failure; return }
        dismiss()
    }
}

/// Add a virtual member, or rename one (lead).
struct PersonEditSheet: View {
    let team: TeamStore
    let person: TeamPerson?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        CaliperSheet(title: person == nil ? "Add a virtual member" : "Edit member") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Name")
                field("Shown as the buyer on their cards", text: $name)
                SectionLabel(text: "Note")
                field("Only your team's leads see this", text: $note)
                Text(error ?? "They don't need the app. You can invite them to link an account later.")
                    .caliperMeta(error == nil ? Caliper.textSecondary : Caliper.confMid)
                    .padding(.horizontal, Caliper.gutter)
                    .padding(.top, Caliper.space5)
            }
        } confirm: {
            CaliperButton(title: person == nil ? "Add member" : "Save", variant: .primary, fullWidth: true,
                          disabled: trimmed(name).isEmpty || team.isWorking) {
                Task {
                    let n = trimmed(name), t = trimmed(note)
                    let failure = if let person {
                        await team.updatePerson(person, name: n, note: t.isEmpty ? nil : t)
                    } else {
                        await team.addPerson(name: n, note: t.isEmpty ? nil : t)
                    }
                    if let failure { error = failure } else { dismiss() }
                }
            }
        }
        .onAppear { name = person?.displayName ?? ""; note = person?.note ?? "" }
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .font(.calBody)
            .autocorrectionDisabled()
            .foregroundStyle(Caliper.textPrimary)
            .padding(.horizontal, Caliper.rowPad)
            .frame(height: Caliper.hitMin)
            .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
            .padding(.horizontal, Caliper.gutter)
    }
}

/// One virtual member, for the lead: invite them to link an account, merge them
/// into someone (the same human entered twice, or a member), unlink, remove.
struct PersonSheet: View {
    let team: TeamStore
    let personId: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var invite: TeamStore.Invite?
    @State private var error: String?
    @State private var editing = false
    @State private var choosingMerge = false
    @State private var confirmRemove = false

    /// Read live from the store, so a rename or link shows at once.
    private var person: TeamPerson? { team.people.first { $0.id == personId } }

    var body: some View {
        CaliperSheet(title: person?.displayName ?? "Member") {
            Button("Done") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            if let person {
                VStack(alignment: .leading, spacing: 0) {
                    SheetRow(label: "Name and note", sub: person.note ?? "No note", trailing: "›") { editing = true }
                    Hairline()
                    if person.isVirtual {
                        SectionLabel(text: "Link to the app")
                        if let invite {
                            Text(JoinCode.display(invite.code))
                                .font(.figureSmall).monospacedDigit()
                                .foregroundStyle(Caliper.textPrimary)
                                .textSelection(.enabled)
                                .padding(.horizontal, Caliper.gutter)
                            Text("They enter it in Settings → Link to a team. Works once"
                                 + (invite.expiresDate.map { ", until \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "")
                                 + ". Then they see the cards tagged to them, read-only.")
                                .caliperMeta()
                                .padding(.horizontal, Caliper.gutter)
                                .padding(.top, Caliper.space3)
                            SheetRow(label: "Make a new code", sub: "The old one stops working") {
                                Task { await makeInvite(rotate: true) }
                            }
                        } else {
                            SheetRow(label: person.linkCodeAt == nil ? "Invite to app" : "Show invite code",
                                     sub: "A one-time code they enter after signing in") {
                                Task { await makeInvite(rotate: false) }
                            }
                        }
                    } else {
                        SectionLabel(text: "Linked")
                        Text("Linked to an account. They see the cards tagged to them, read-only.")
                            .caliperMeta()
                            .padding(.horizontal, Caliper.gutter)
                        SheetRow(label: "Unlink account", sub: "Their tagged cards stay tagged") {
                            act { await team.unlink(person) }
                        }
                    }
                    Hairline()
                    SheetRow(label: "Merge into…", sub: "Same person entered twice? Their cards move over") {
                        choosingMerge = true
                    }
                    Hairline()
                    SheetRow(label: "Remove", sub: "Only once no cards are tagged to them") { confirmRemove = true }
                    if let error {
                        Text(error)
                            .caliperMeta(Caliper.confMid)
                            .padding(.horizontal, Caliper.gutter)
                            .padding(.top, Caliper.space5)
                    }
                }
            } else {
                Text("This member is no longer on the roster.")
                    .caliperMeta()
                    .padding(Caliper.gutter)
            }
        } confirm: {
            EmptyView()
        }
        .sheet(isPresented: $editing) { PersonEditSheet(team: team, person: person) }
        .confirmationDialog("Merge \(person?.displayName ?? "") into…", isPresented: $choosingMerge,
                            titleVisibility: .visible) {
            ForEach(team.buyerChoices.filter { $0.id != personId }) { target in
                Button(target.isVirtual ? "\(target.name) · virtual" : target.name) {
                    Task { await merge(into: target) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every card tagged to \(person?.displayName ?? "them") moves to the one you pick, and this entry is removed.")
        }
        .confirmationDialog("Remove \(person?.displayName ?? "")?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    guard let person else { return }
                    if let failure = await team.removePerson(person) { error = failure } else { dismiss() }
                }
            }
        }
    }

    private func makeInvite(rotate: Bool) async {
        guard let person else { return }
        error = nil
        switch await team.invite(person, rotate: rotate) {
        case .success(let made): invite = made
        case .failure(let failure): error = failure.copy
        }
    }

    private func merge(into target: Buyer) async {
        guard let absorb = person else { return }
        error = nil
        let (keepId, failure) = await team.personId(for: target)
        if let failure { error = failure; return }
        guard let keep = team.people.first(where: { $0.id == keepId }) else { return }
        if let failure = await team.merge(keep: keep, absorb: absorb) { error = failure; return }
        CardTagging.retag(from: absorb.id, to: target, in: context)
        dismiss()
    }

    private func act(_ work: @escaping () async -> String?) {
        error = nil
        Task { error = await work() }
    }
}
