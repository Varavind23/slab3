import SwiftUI

/// Create or edit a buy range (plan §7.8). One sheet for the library and for a
/// lot's own copy, because they are the same eight criteria.
///
/// Every criterion is a min/max PAIR in mono fields, side by side, so the range
/// reads left-to-right the way a lead says it ("grade seven to ten"). A blank bound
/// is "no limit" and says so in its placeholder, except value's min (0) and grade
/// (1–10), which always have one. Problems are shown against the field that has
/// them, before any request — the server's CHECKs are the same rules, but a 400
/// cannot say which box is wrong.
struct BuyRangeEditorSheet: View {
    let title: String
    let initial: BuyRangeDraft
    /// Leads edit; everyone else reads the same layout with the fields locked.
    var readOnly = false
    /// Offered when adding a new range to a lot: also file it in the library.
    var offersSaveToLibrary = false
    let onSave: (BuyRangeFields, _ saveToLibrary: Bool) async -> String?
    var onDelete: (() async -> String?)?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = BuyRangeDraft()
    @State private var saveToLibrary = false
    @State private var showIssues = false
    @State private var serverError: String?
    @State private var working = false
    @State private var confirmDelete = false

    private var validation: BuyRangeDraft.Validation { draft.validated() }

    var body: some View {
        CaliperSheet(title: title) {
            Button(readOnly ? "Done" : "Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                section("Name", issue: .name) {
                    field("Buyers under $100", text: $draft.name)
                }
                section("Value · CL", issue: .value) {
                    pair(min: $draft.valueMin, minPrompt: "$0", max: $draft.valueMax, maxPrompt: "No max", decimal: true)
                }
                section("Grade", issue: .grade) {
                    pair(min: $draft.gradeMin, minPrompt: "1", max: $draft.gradeMax, maxPrompt: "10", decimal: true)
                }
                section("CL confidence · 1–5", issue: .confidence) {
                    pair(min: $draft.confMin, minPrompt: "Any", max: $draft.confMax, maxPrompt: "Any")
                }
                section("Year", issue: .year) {
                    pair(min: $draft.yearMin, minPrompt: "Any", max: $draft.yearMax, maxPrompt: "Any")
                }
                HStack(alignment: .top, spacing: Caliper.space5) {
                    VStack(alignment: .leading, spacing: 0) {
                        label("Max cards", issue: .maxCards)
                        field("400", text: $draft.maxCards, mono: true, keyboard: .numberPad)
                        issueText(.maxCards)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        label("Budget · $", issue: .budget)
                        field("45,100", text: $draft.budget, mono: true, keyboard: .decimalPad)
                        issueText(.budget)
                    }
                }
                .padding(.horizontal, Caliper.gutter)

                section("Notes", issue: nil) {
                    TextField("For the buyers — what to look for, what to skip",
                              text: $draft.notes, axis: .vertical)
                        .font(.calBody)
                        .lineLimit(2...6)
                        .foregroundStyle(Caliper.textPrimary)
                        .padding(Caliper.rowPad)
                        .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                        .disabled(readOnly)
                }

                if offersSaveToLibrary && !readOnly {
                    HStack {
                        Text("Save to the team's library").font(.calBody).foregroundStyle(Caliper.textPrimary)
                        Spacer()
                        CaliperSwitch(isOn: $saveToLibrary)
                    }
                    .padding(.horizontal, Caliper.gutter)
                    .frame(minHeight: Caliper.hitMin)
                    .padding(.top, Caliper.space6)
                }

                if let serverError {
                    Text(serverError)
                        .caliperMeta(Caliper.confMid)
                        .padding(.horizontal, Caliper.gutter)
                        .padding(.top, Caliper.space5)
                }

                if onDelete != nil && !readOnly {
                    Button { confirmDelete = true } label: {
                        Text("Delete range")
                            .caliperLabel(Caliper.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Caliper.gutter)
                            .frame(minHeight: Caliper.hitMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CaliperPressStyle())
                    .padding(.top, Caliper.space7)
                }
            }
        } confirm: {
            if !readOnly {
                CaliperButton(title: "Save range", variant: .primary, fullWidth: true,
                              disabled: working || (showIssues && validation.fields == nil)) {
                    Task { await save() }
                }
            }
        }
        .onAppear { draft = initial }
        .confirmationDialog("Delete \(draft.name.isEmpty ? "this range" : draft.name)?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete range", role: .destructive) {
                Task {
                    guard let onDelete else { return }
                    working = true
                    if let failure = await onDelete() { serverError = failure } else { dismiss() }
                    working = false
                }
            }
        }
    }

    private func save() async {
        // Problems only appear once the lead tries to save — a half-typed range is
        // not an error, and red text while typing reads as nagging.
        showIssues = true
        guard let fields = validation.fields else { return }
        working = true
        serverError = await onSave(fields, saveToLibrary)
        working = false
        if serverError == nil { dismiss() }
    }

    // MARK: Pieces

    private func section<C: View>(_ title: String, issue: BuyRangeDraft.Field?,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            label(title, issue: issue)
            content()
            if let issue { issueText(issue) }
        }
        .padding(.horizontal, Caliper.gutter)
    }

    private func label(_ text: String, issue: BuyRangeDraft.Field?) -> some View {
        let flagged = showIssues && issue.map { validation.issues[$0] != nil } == true
        return Text(text)
            .caliperLabel(flagged ? Caliper.confMid : Caliper.textTertiary)
            .padding(.top, Caliper.space7)
            .padding(.bottom, Caliper.space4)
    }

    @ViewBuilder
    private func issueText(_ field: BuyRangeDraft.Field) -> some View {
        if showIssues, let message = validation.issues[field] {
            Text(message).caliperMeta(Caliper.confMid).padding(.top, Caliper.space3)
        }
    }

    private func pair(min: Binding<String>, minPrompt: String,
                      max: Binding<String>, maxPrompt: String, decimal: Bool = false) -> some View {
        HStack(spacing: Caliper.space4) {
            field(minPrompt, text: min, mono: true, keyboard: decimal ? .decimalPad : .numberPad)
            Text("to").caliperMeta(Caliper.textTertiary)
            field(maxPrompt, text: max, mono: true, keyboard: decimal ? .decimalPad : .numberPad)
        }
    }

    private func field(_ prompt: String, text: Binding<String>, mono: Bool = false,
                       keyboard: UIKeyboardType = .default) -> some View {
        TextField(prompt, text: text)
            .font(mono ? .price : .calBody)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .foregroundStyle(Caliper.textPrimary)
            .padding(.horizontal, Caliper.rowPad)
            .frame(height: Caliper.hitMin)
            .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
            .disabled(readOnly)
    }
}

/// One range as a row: name and value on top, criteria and caps beneath — the
/// same order the lot view's range panel will use (plan §7.4).
struct BuyRangeRow: View {
    let range: BuyRange
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: Caliper.space2) {
                HStack {
                    Text(range.name).font(.calBody).foregroundStyle(Caliper.textPrimary).lineLimit(1)
                    Spacer(minLength: Caliper.space4)
                    Text(range.valueLabel).font(.price).foregroundStyle(Caliper.textPrimary)
                }
                HStack {
                    Text(range.criteriaLine).caliperMeta(Caliper.textSecondary)
                    Spacer(minLength: Caliper.space4)
                    Text(range.capsLine).caliperMeta(Caliper.textSecondary)
                }
                if let notes = range.notes {
                    Text(notes).caliperMeta(Caliper.textTertiary).lineLimit(1)
                }
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.vertical, Caliper.space5)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
    }
}

/// The team's saved ranges (Settings → Team → Buy ranges). A lead builds them once
/// and drops copies into each lot; everyone else can read them.
struct BuyRangeLibrarySheet: View {
    let team: TeamStore
    let lots: LotStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: EditTarget?

    enum EditTarget: Identifiable {
        case new, existing(BuyRange)
        var id: String {
            switch self { case .new: "new"; case .existing(let r): r.id.uuidString }
        }
    }

    var body: some View {
        CaliperSheet(title: "Buy ranges · \(lots.library.count)") {
            Button("Done") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(spacing: 0) {
                ForEach(lots.library) { range in
                    BuyRangeRow(range: range) { editing = .existing(range) }
                    Hairline()
                }
                if lots.library.isEmpty {
                    Text(team.isLead
                         ? "No saved ranges yet. A range you save here can be added to any lot."
                         : "Your lead hasn't saved any ranges yet.")
                        .font(.calBody)
                        .foregroundStyle(Caliper.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Caliper.gutter)
                        .padding(.vertical, Caliper.space6)
                }
            }
        } confirm: {
            if team.isLead {
                CaliperButton(title: "New range", variant: .primary, fullWidth: true) { editing = .new }
            }
        }
        .sheet(item: $editing) { target in
            editor(for: target).presentationDetents([.large])
        }
    }

    @ViewBuilder
    private func editor(for target: EditTarget) -> some View {
        let teamId = team.team?.id
        switch target {
        case .new:
            BuyRangeEditorSheet(title: "New range", initial: BuyRangeDraft()) { fields, _ in
                guard let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.saveTemplate(fields, id: nil, teamId: teamId)
            }
        case .existing(let range):
            BuyRangeEditorSheet(title: range.name, initial: BuyRangeDraft(range), readOnly: !team.isLead,
                                onSave: { fields, _ in
                guard let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.saveTemplate(fields, id: range.id, teamId: teamId)
            }, onDelete: {
                guard let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.deleteTemplate(range.id, teamId: teamId)
            })
        }
    }
}
