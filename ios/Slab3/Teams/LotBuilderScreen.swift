import SwiftUI

/// Build or edit a lot on ONE screen (teams-first plan, D6) — pushed from Teams.
///
/// It replaced a setup sheet a lead reached ~10 taps deep, with bands and
/// categories to manage before a bucket could be added. Now, top to bottom: name,
/// deadline, the banner buyers see; then the lot's buckets, with the team's saved
/// ranges right under them — one tap drops a copy in — and "New range" for
/// anything else. Nothing is written until the lead saves (LotBuilderDraft).
///
/// Buttons: a cyan "Open lot" (a draft or new lot) or "Save" (an open or closed
/// one) — the one primary action — plus "Save draft" and, for a draft, "Delete".
struct LotBuilderScreen: View {
    @Bindable var app: AppState
    /// nil: a new lot.
    let lotId: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var draft = LotBuilderDraft()
    @State private var loadedFor: UUID??
    @State private var editing: EditTarget?
    @State private var problem: String?
    @State private var working = false
    @State private var confirmDiscard = false
    @State private var confirmDelete = false

    enum EditTarget: Identifiable {
        case new
        case bucket(LotBuilderDraft.Bucket)
        var id: String {
            switch self { case .new: "new"; case .bucket(let b): b.id.uuidString }
        }
    }

    /// The lot as the server has it — nil until a new lot's first save lands.
    private var existing: Lot? { app.lots.lots.first { $0.id == draft.lotId } }
    private var existingRanges: [BuyRange] { existing.map(app.lots.ranges(for:)) ?? [] }
    private var status: LotStatus { existing?.status ?? .draft }
    /// Buckets that already hold slabs.
    private var held: Set<UUID> {
        Set(app.lots.claims(for: existing ?? Lot(id: draft.lotId, name: "", deadline: nil, status: .draft,
                                                createdAt: Date())).compactMap(\.rangeId))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(context: existing.map(LotText.statusLine) ?? "New lot · a draft until you open it",
                         title: draft.trimmedName.isEmpty ? (lotId == nil ? "New lot" : "Lot") : draft.trimmedName) {
                Button(isDirty ? "Cancel" : "Done") { leave() }
                    .font(.mono(10, .medium))
                    .foregroundStyle(Caliper.textSecondary)
                    .frame(minHeight: Caliper.hitMin)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    details
                    bucketsSection
                    librarySection
                }
                .padding(.bottom, Caliper.space8)
            }
            actions
        }
        .onAppear(perform: load)
        .sheet(item: $editing) { target in editor(for: target).presentationDetents([.large]) }
        .confirmationDialog("Leave without saving?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            if status == .draft { Button("Save draft") { Task { await save(status: .draft, thenLeave: true) } } }
        }
        .confirmationDialog("Delete this draft?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete draft", role: .destructive) { Task { await deleteDraft() } }
        } message: {
            Text("Buyers never saw it. Its buckets go with it; your saved ranges stay.")
        }
    }

    private var isDirty: Bool { draft.differs(from: existing, ranges: existingRanges) }

    // MARK: Name, deadline, banner

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Name")
            textField("Weekend 10/4", text: $draft.name)
            SectionLabel(text: "Submit deadline")
            HStack {
                Text(draft.hasDeadline ? "Due" : "No deadline").font(.calBody).foregroundStyle(Caliper.textPrimary)
                Spacer()
                if draft.hasDeadline {
                    DatePicker("", selection: $draft.deadline, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .tint(Caliper.cyan)
                }
                CaliperSwitch(isOn: $draft.hasDeadline)
            }
            .padding(.horizontal, Caliper.gutter)
            .frame(minHeight: Caliper.hitMin)
            SectionLabel(text: "Banner · shown to buyers")
            textField("e.g. PSA only — no CGC, no BGS", text: $draft.banner)
        }
    }

    // MARK: Buckets

    private var bucketsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Buckets · \(draft.buckets.count)")
                Button { editing = .new } label: {
                    Label("New range", systemImage: "plus")
                        .font(.mono(10, .medium))
                        .foregroundStyle(Caliper.textSecondary)
                        .frame(minHeight: Caliper.hitMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(CaliperPressStyle())
                .padding(.trailing, Caliper.gutter)
                .padding(.top, Caliper.space5)
            }
            Hairline()
            ForEach(draft.buckets) { bucket in
                HStack(spacing: 0) {
                    BuyRangeRow(range: preview(bucket)) { editing = .bucket(bucket) }
                    Button { remove(bucket) } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(held.contains(bucket.id) ? Caliper.textTertiary : Caliper.textSecondary)
                            .frame(width: Caliper.hitMin, height: Caliper.hitMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CaliperPressStyle())
                    .accessibilityLabel("Remove \(bucket.fields.name)")
                    .padding(.trailing, Caliper.space4)
                }
                Hairline()
            }
            if draft.buckets.isEmpty {
                Text("No buckets yet. Tap a saved range below, or add a new one.")
                    .caliperMeta()
                    .padding(.horizontal, Caliper.gutter)
                    .padding(.top, Caliper.space5)
            }
        }
    }

    /// The team's saved ranges not already in this lot — one tap adds a copy.
    private var librarySection: some View {
        let used = Set(draft.buckets.compactMap(\.templateId))
        let available = app.lots.library.filter { !used.contains($0.id) }
        return VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "From your saved ranges · tap to add")
            Hairline()
            ForEach(available) { range in
                HStack(spacing: 0) {
                    BuyRangeRow(range: range) { withAnimation(Caliper.easeOut) { draft.add(template: range) } }
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Caliper.textSecondary)
                        .frame(width: Caliper.hitMin)
                        .padding(.trailing, Caliper.space4)
                        .accessibilityHidden(true)
                }
                Hairline()
            }
            if available.isEmpty {
                Text(app.lots.library.isEmpty
                     ? "No saved ranges. \"New range\" can save one to the library as you add it."
                     : "Every saved range is in this lot.")
                    .caliperMeta()
                    .padding(.horizontal, Caliper.gutter)
                    .padding(.top, Caliper.space5)
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: Caliper.space4) {
            Hairline()
            if let problem {
                Text(problem).caliperMeta(Caliper.confMid)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Caliper.gutter)
            }
            if status == .draft {
                CaliperButton(title: "Open lot", variant: .primary, fullWidth: true, disabled: working) {
                    Task { await save(status: .active, thenLeave: true) }
                }
                .padding(.horizontal, Caliper.gutter)
                HStack(spacing: Caliper.space4) {
                    CaliperButton(title: "Save draft", fullWidth: true, disabled: working || !isDirty) {
                        Task { await save(status: .draft, thenLeave: false) }
                    }
                    if existing != nil {
                        CaliperButton(title: "Delete", variant: .text, disabled: working) { confirmDelete = true }
                    }
                }
                .padding(.horizontal, Caliper.gutter)
            } else {
                CaliperButton(title: "Save", variant: .primary, fullWidth: true, disabled: working || !isDirty) {
                    Task { await save(status: status, thenLeave: true) }
                }
                .padding(.horizontal, Caliper.gutter)
            }
        }
        .padding(.bottom, Caliper.space4)
        .background(Caliper.bg)
    }

    // MARK: Work

    private func load() {
        guard loadedFor == nil else { return }
        loadedFor = .some(lotId)
        if let lotId, let lot = app.lots.lots.first(where: { $0.id == lotId }) {
            draft = LotBuilderDraft(lot: lot, ranges: app.lots.ranges(for: lot))
        }
    }

    private func leave() {
        if isDirty { confirmDiscard = true } else { dismiss() }
    }

    private func remove(_ bucket: LotBuilderDraft.Bucket) {
        if held.contains(bucket.id) {
            problem = "That bucket already has cards in it — it stays while they do."
            return
        }
        withAnimation(Caliper.easeOut) { draft.buckets.removeAll { $0.id == bucket.id } }
    }

    private func save(status target: LotStatus, thenLeave: Bool) async {
        problem = draft.problem(opening: target == .active && status == .draft,
                                existing: existingRanges, held: held)
        guard problem == nil, let teamId = app.team.team?.id else { return }
        working = true
        defer { working = false }
        let ops = draft.operations(existingLot: existing, existingRanges: existingRanges, status: target)
        if let failure = await app.lots.apply(ops, teamId: teamId) {
            // What landed stays; the store reloaded, so the next try sends the rest.
            problem = failure
            return
        }
        if thenLeave { dismiss() }
    }

    private func deleteDraft() async {
        guard let existing, let teamId = app.team.team?.id else { return }
        working = true
        defer { working = false }
        if let failure = await app.lots.deleteDraft(existing, teamId: teamId) { problem = failure } else { dismiss() }
    }

    /// A draft bucket drawn with the library's row.
    private func preview(_ bucket: LotBuilderDraft.Bucket) -> BuyRange {
        let f = bucket.fields
        return BuyRange(id: bucket.id, name: f.name, valueMinCents: f.valueMinCents, valueMaxCents: f.valueMaxCents,
                        gradeMin: f.gradeMin, gradeMax: f.gradeMax, clConfMin: f.clConfMin, clConfMax: f.clConfMax,
                        yearMin: f.yearMin, yearMax: f.yearMax, maxCards: f.maxCards, budgetCents: f.budgetCents,
                        notes: f.notes, band: f.band)
    }

    @ViewBuilder
    private func editor(for target: EditTarget) -> some View {
        let labels = LotDashboard.bandLabels(draft.buckets.map(preview))
        switch target {
        case .new:
            BuyRangeEditorSheet(title: "New range", initial: BuyRangeDraft(), offersSaveToLibrary: true,
                                bandSuggestions: labels) { fields, saveToLibrary in
                var templateId: UUID?
                if saveToLibrary, let teamId = app.team.team?.id {
                    if let failure = await app.lots.saveTemplate(fields, id: nil, teamId: teamId) { return failure }
                    templateId = app.lots.library.first { $0.fields == fields }?.id
                }
                draft.buckets.append(.init(fields: fields, templateId: templateId))
                return nil
            }
        case .bucket(let bucket):
            // Edits change THIS lot's copy only, never the library.
            BuyRangeEditorSheet(title: bucket.fields.name, initial: BuyRangeDraft(preview(bucket)),
                                bandSuggestions: labels) { fields, _ in
                if let i = draft.buckets.firstIndex(where: { $0.id == bucket.id }) { draft.buckets[i].fields = fields }
                return nil
            }
        }
    }

    private func textField(_ prompt: String, text: Binding<String>) -> some View {
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
