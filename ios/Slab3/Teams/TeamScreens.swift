import SwiftUI

// Settings → Team (plan §7.7). Joining is by code, never by invitation (owner
// decision): the lead reads a six-character code across the table and the buyer
// types it. No email, no link, no approval step. Being on a team is what turns
// every other team feature on, so this is the only door.

/// Join an existing team by code, or start one. One sheet, two modes — starting a
/// team is the rarer path (one lead, many buyers), so joining is what it opens on.
struct TeamOnboardSheet: View {
    let team: TeamStore
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
                    Text("Your lead finds it in Settings → Team.")
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
        if let failure { error = failure } else { dismiss() }
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
struct TeamMembersSheet: View {
    let team: TeamStore
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmLeave = false

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
