import SwiftUI

/// Set up one lot: name, deadline, and its buy ranges (plan §7.8). New lots start
/// as drafts; "Open lot" is the moment buyers see it. A buyer opening this sees the
/// same screen read-only — the ranges and their notes are what they buy against.
struct LotSetupSheet: View {
    let team: TeamStore
    let lots: LotStore
    /// nil while creating; set as soon as the draft exists on the server.
    @State var lotId: UUID?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hasDeadline = false
    @State private var deadline = LotText.defaultDeadline()
    @State private var error: String?
    @State private var editing: RangeTarget?
    @State private var pickingFromLibrary = false
    /// Which band "+ From library" adds into (nil = a bucket of its own).
    @State private var libraryBand: UUID?
    @State private var banner = ""
    @State private var bandSheet: BandTarget?
    @State private var confirmClose = false
    @State private var confirmDelete = false
    @State private var seeded = false

    enum RangeTarget: Identifiable {
        /// A new bucket, into this band (nil = standing on its own).
        case new(UUID?), existing(BuyRange), fromTemplate(BuyRange, UUID?)
        var id: String {
            switch self {
            case .new(let band): "new" + (band?.uuidString ?? "")
            case .existing(let r): "e" + r.id.uuidString
            case .fromTemplate(let r, _): "t" + r.id.uuidString
            }
        }
    }

    enum BandTarget: Identifiable {
        case new, existing(LotBand)
        var id: String { switch self { case .new: "new"; case .existing(let b): b.id.uuidString } }
    }

    private var lot: Lot? { lotId.flatMap { id in lots.lots.first { $0.id == id } } }
    private var ranges: [BuyRange] { lot.map(lots.ranges(for:)) ?? [] }
    private var bands: [LotBand] { lot.map(lots.bands(for:)) ?? [] }
    private var categories: [String] {
        var seen: [String] = []
        for c in bands.compactMap(\.category) where !seen.contains(c) { seen.append(c) }
        return seen
    }
    private var canEdit: Bool { team.isLead && lot?.status != .closed }
    private var teamId: UUID? { team.team?.id }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        CaliperSheet(title: lot?.name ?? "New lot") {
            Button(lot == nil || !canEdit ? "Cancel" : "Done") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                if let lot {
                    Text(LotText.statusLine(lot))
                        .caliperLabel(lot.status == .active ? Caliper.textPrimary : Caliper.textTertiary)
                        .padding(.horizontal, Caliper.gutter)
                        .padding(.top, Caliper.space6)
                }

                SectionLabel(text: "Name")
                TextField("Show 7/24", text: $name)
                    .font(.calBody)
                    .autocorrectionDisabled()
                    .foregroundStyle(Caliper.textPrimary)
                    .padding(.horizontal, Caliper.rowPad)
                    .frame(height: Caliper.hitMin)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                    .padding(.horizontal, Caliper.gutter)
                    .disabled(!team.isLead)

                SectionLabel(text: "Submit deadline")
                HStack {
                    Text(hasDeadline ? "Deadline set" : "No deadline")
                        .font(.calBody).foregroundStyle(Caliper.textPrimary)
                    Spacer()
                    if team.isLead { CaliperSwitch(isOn: $hasDeadline) }
                }
                .padding(.horizontal, Caliper.gutter)
                .frame(minHeight: Caliper.hitMin)
                if hasDeadline {
                    DatePicker("Deadline", selection: $deadline, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .tint(Caliper.cyan)
                        .padding(.horizontal, Caliper.gutter)
                        .disabled(!team.isLead)
                }

                SectionLabel(text: "Warning banner")
                TextField("e.g. Only accepting PSA slabs", text: $banner, axis: .vertical)
                    .font(.calBody)
                    .lineLimit(1...3)
                    .foregroundStyle(Caliper.textPrimary)
                    .padding(Caliper.rowPad)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                    .padding(.horizontal, Caliper.gutter)
                    .disabled(!team.isLead)

                if lot != nil { bandsSection }

                if let error {
                    Text(error)
                        .caliperMeta(Caliper.confMid)
                        .padding(.horizontal, Caliper.gutter)
                        .padding(.top, Caliper.space5)
                }

                if let lot, team.isLead { lifecycleAction(lot) }
            }
        } confirm: {
            confirmButton
        }
        .onAppear(perform: seed)
        .onChange(of: lot) { _, _ in seed() }
        .sheet(item: $editing) { rangeEditor(for: $0).presentationDetents([.large]) }
        .sheet(isPresented: $pickingFromLibrary) { libraryPicker.presentationDetents([.large]) }
        .sheet(item: $bandSheet) { target in
            bandEditor(for: target).presentationDetents([.medium])
        }
        .confirmationDialog("Close \(lot?.name ?? "this lot")?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close lot") { Task { await setStatus(.closed) } }
        } message: {
            Text("It stops taking cards. Everything already bought stays in it.")
        }
        .confirmationDialog("Delete this draft?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete draft", role: .destructive) {
                Task {
                    guard let lot, let teamId else { return }
                    if let failure = await lots.deleteDraft(lot, teamId: teamId) { error = failure } else { dismiss() }
                }
            }
        }
    }

    // MARK: Bands and their buckets

    /// Bands in lot order, each with its buckets; buckets with no band last, each
    /// standing as a band of one on the dashboard. A band's price span is shown as
    /// its buckets make it — it has none of its own.
    @ViewBuilder private var bandsSection: some View {
        SectionLabel(text: "Bands & buckets · \(ranges.count)")
        if ranges.isEmpty && bands.isEmpty {
            Text("A lot takes only cards that fit one of its buckets. Add a band, then its buckets, before opening it.")
                .caliperMeta()
                .padding(.horizontal, Caliper.gutter)
                .padding(.bottom, Caliper.space4)
        }
        ForEach(bands.sorted { $0.sortOrder < $1.sortOrder }) { band in
            let members = ranges.filter { $0.bandId == band.id }.sorted { $0.valueMinCents < $1.valueMinCents }
            bandHeader(band, members)
            ForEach(members) { range in bucketRow(range) }
            if canEdit { bucketButtons(band: band.id) }
        }
        let loose = ranges.filter { r in r.bandId.map { id in !bands.contains { $0.id == id } } ?? true }
        if !loose.isEmpty {
            Text("No band").caliperLabel(Caliper.textTertiary)
                .padding(.horizontal, Caliper.gutter)
                .padding(.top, Caliper.space6)
                .padding(.bottom, Caliper.space3)
            ForEach(loose) { range in bucketRow(range) }
        }
        if canEdit {
            CaliperButton(title: "+ New band", variant: .outline, fullWidth: true) { bandSheet = .new }
                .padding(.horizontal, Caliper.gutter)
                .padding(.top, Caliper.space6)
        }
    }

    private func bandHeader(_ band: LotBand, _ members: [BuyRange]) -> some View {
        let span = members.isEmpty ? "No buckets yet"
            : BuyRangeText.value(min: members.map(\.valueMinCents).min() ?? 0,
                                 max: members.contains { $0.valueMaxCents == nil } ? nil
                                    : members.compactMap(\.valueMaxCents).max())
        return Button { if canEdit { bandSheet = .existing(band) } } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(span).font(.calHeading).foregroundStyle(Caliper.textPrimary)
                    Text(band.category ?? "No category").caliperLabel(Caliper.textSecondary)
                }
                Spacer()
                Text(members.count == 1 ? "1 bucket" : "\(members.count) buckets").caliperMeta()
                if canEdit {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Caliper.textTertiary)
                }
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space6)
            .padding(.bottom, Caliper.space3)
            .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .disabled(!canEdit)
    }

    private func bucketRow(_ range: BuyRange) -> some View {
        VStack(spacing: 0) {
            BuyRangeRow(range: range) { editing = .existing(range) }
                .contextMenu {
                    if canEdit {
                        Menu("Move to band") {
                            ForEach(bands.filter { $0.id != range.bandId }) { band in
                                Button(bandMenuTitle(band)) { move(range, to: band.id) }
                            }
                            if range.bandId != nil {
                                Button("No band") { move(range, to: nil) }
                            }
                        }
                    }
                }
            Hairline()
        }
        .padding(.leading, Caliper.space6)
    }

    private func bucketButtons(band: UUID?) -> some View {
        HStack(spacing: Caliper.space4) {
            CaliperButton(title: "+ Bucket", variant: .outline, fullWidth: true) { editing = .new(band) }
            CaliperButton(title: "+ From library", variant: .outline, fullWidth: true,
                          disabled: lots.library.isEmpty) {
                libraryBand = band
                pickingFromLibrary = true
            }
        }
        .padding(.horizontal, Caliper.gutter)
        .padding(.leading, Caliper.space6)
        .padding(.top, Caliper.space4)
    }

    private func bandMenuTitle(_ band: LotBand) -> String {
        let members = ranges.filter { $0.bandId == band.id }
        let span = members.isEmpty ? "empty"
            : BuyRangeText.value(min: members.map(\.valueMinCents).min() ?? 0,
                                 max: members.compactMap(\.valueMaxCents).max())
        return [band.category, span].compactMap { $0 }.joined(separator: " · ")
    }

    private func move(_ range: BuyRange, to band: UUID?) {
        guard let teamId else { return }
        Task { error = await lots.moveRange(range.id, toBand: band, teamId: teamId) }
    }

    @ViewBuilder
    private func bandEditor(for target: BandTarget) -> some View {
        switch target {
        case .new:
            BandCategorySheet(title: "New band", initial: categories.first ?? "", suggestions: categories) { category in
                guard let lotId, let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.addBand(to: lotId, category: category, teamId: teamId)
            }
        case .existing(let band):
            BandCategorySheet(title: "Band", initial: band.category ?? "", suggestions: categories,
                              onSave: { category in
                guard let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.updateBand(band, category: category, teamId: teamId)
            }, onDelete: {
                guard let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.deleteBand(band, teamId: teamId)
            })
        }
    }

    // MARK: Confirm + lifecycle

    @ViewBuilder private var confirmButton: some View {
        if !team.isLead {
            EmptyView()
        } else if let lot {
            switch lot.status {
            case .draft:
                // Opening is the one thing this screen is for once ranges exist.
                CaliperButton(title: "Open lot", variant: .primary, fullWidth: true,
                              disabled: ranges.isEmpty || trimmedName.isEmpty || lots.isWorking) {
                    Task { await setStatus(.active) }
                }
            case .active:
                CaliperButton(title: "Save", variant: .primary, fullWidth: true,
                              disabled: !detailsChanged(lot) || trimmedName.isEmpty || lots.isWorking) {
                    Task { await setStatus(.active) }
                }
            case .closed:
                EmptyView()
            }
        } else {
            CaliperButton(title: "Create lot", variant: .primary, fullWidth: true,
                          disabled: trimmedName.isEmpty || lots.isWorking) {
                Task { await create() }
            }
        }
    }

    @ViewBuilder
    private func lifecycleAction(_ lot: Lot) -> some View {
        switch lot.status {
        case .draft: textAction("Delete draft", tint: Caliper.danger) { confirmDelete = true }
        case .active: textAction("Close lot", tint: Caliper.textSecondary) { confirmClose = true }
        case .closed: textAction("Reopen lot", tint: Caliper.textSecondary) { Task { await setStatus(.active) } }
        }
    }

    private func textAction(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .caliperLabel(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Caliper.gutter)
                .frame(minHeight: Caliper.hitMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(CaliperPressStyle())
        .padding(.top, Caliper.space7)
    }

    private func detailsChanged(_ lot: Lot) -> Bool {
        let b = banner.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName != lot.name || (hasDeadline ? deadline : nil) != lot.deadline
            || (b.isEmpty ? nil : b) != lot.banner
    }

    private func seed() {
        guard !seeded else { return }
        if let lot {
            name = lot.name
            banner = lot.banner ?? ""
            hasDeadline = lot.deadline != nil
            if let d = lot.deadline { deadline = d }
            seeded = true
        } else if lotId == nil {
            seeded = true
        }
    }

    private func create() async {
        guard let teamId else { return }
        error = nil
        let trimmedBanner = banner.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = await lots.createLot(name: trimmedName, deadline: hasDeadline ? deadline : nil,
                                           banner: trimmedBanner.isEmpty ? nil : trimmedBanner, teamId: teamId)
        if let id = created.id { lotId = id } else { error = created.error }
    }

    private func setStatus(_ status: LotStatus) async {
        guard let lotId, let teamId else { return }
        error = nil
        let trimmedBanner = banner.trimmingCharacters(in: .whitespacesAndNewlines)
        error = await lots.updateLot(lotId, name: trimmedName, deadline: hasDeadline ? deadline : nil,
                                     banner: trimmedBanner.isEmpty ? nil : trimmedBanner,
                                     status: status, teamId: teamId)
    }

    // MARK: Ranges

    @ViewBuilder
    private func rangeEditor(for target: RangeTarget) -> some View {
        switch target {
        case .new(let band):
            BuyRangeEditorSheet(title: "New bucket", initial: BuyRangeDraft(), offersSaveToLibrary: true) { fields, save in
                guard let lotId, let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.addRange(fields, to: lotId, band: band, fromTemplate: nil,
                                           saveToLibrary: save, teamId: teamId)
            }
        case .fromTemplate(let template, let band):
            // Editable before it lands: a library range is a starting point, and
            // this lot may need it a little different.
            BuyRangeEditorSheet(title: "Add \(template.name)", initial: BuyRangeDraft(template)) { fields, _ in
                guard let lotId, let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.addRange(fields, to: lotId, band: band, fromTemplate: template.id,
                                           saveToLibrary: false, teamId: teamId)
            }
        case .existing(let range):
            BuyRangeEditorSheet(title: range.name, initial: BuyRangeDraft(range), readOnly: !canEdit,
                                onSave: { fields, _ in
                guard let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.updateRange(range.id, fields: fields, teamId: teamId)
            }, onDelete: {
                guard let teamId else { return TeamError.copy(for: "not_member") }
                return await lots.deleteRange(range.id, teamId: teamId)
            })
        }
    }

    private var libraryPicker: some View {
        CaliperSheet(title: "Add from library") {
            Button("Cancel") { pickingFromLibrary = false }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(spacing: 0) {
                ForEach(lots.library) { template in
                    BuyRangeRow(range: template) {
                        pickingFromLibrary = false
                        // Let the picker finish dismissing before the editor rises.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            editing = .fromTemplate(template, libraryBand)
                        }
                    }
                    Hairline()
                }
            }
        } confirm: { EmptyView() }
    }
}

/// How lots read. Deadlines render in LOCAL time — a card show is somewhere, and
/// the lead set the deadline in their own clock.
enum LotText {
    static func statusTitle(_ status: LotStatus) -> String {
        switch status {
        case .active: "Open"
        case .draft: "Drafts · only leads see these"
        case .closed: "Closed"
        }
    }

    static func statusLine(_ lot: Lot) -> String {
        switch lot.status {
        case .draft: "Draft · buyers can't see it yet"
        case .active: "Open · buyers are filing into it"
        case .closed: "Closed · takes no more cards"
        }
    }

    /// `Due Sep 26 · 17:00 · 3 ranges`
    static func summary(_ lot: Lot, rangeCount: Int) -> String {
        var parts: [String] = []
        if let d = lot.deadline { parts.append("Due " + deadline(d)) }
        parts.append(rangeCount == 1 ? "1 range" : "\(rangeCount) ranges")
        return parts.joined(separator: " · ")
    }

    static func deadline(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day()) + " · "
            + date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// Five o'clock, three days out — somewhere plausible to start the picker.
    static func defaultDeadline(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: 3, to: now) ?? now
        return cal.date(bySettingHour: 17, minute: 0, second: 0, of: day) ?? day
    }
}

/// Name a band's category (Pokémon, Sports, …) — what the dashboard's CATEGORY
/// selector switches between. Existing categories are one tap, so two bands meant
/// for the same category can't drift apart by a typo.
struct BandCategorySheet: View {
    let title: String
    let initial: String
    let suggestions: [String]
    let onSave: (String?) async -> String?
    var onDelete: (() async -> String?)?

    @Environment(\.dismiss) private var dismiss
    @State private var category = ""
    @State private var error: String?
    @State private var confirmDelete = false

    var body: some View {
        CaliperSheet(title: title) {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Category")
                TextField("Pokémon", text: $category)
                    .font(.calBody)
                    .autocorrectionDisabled()
                    .foregroundStyle(Caliper.textPrimary)
                    .padding(.horizontal, Caliper.rowPad)
                    .frame(height: Caliper.hitMin)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
                    .padding(.horizontal, Caliper.gutter)
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Caliper.space4) {
                            ForEach(suggestions, id: \.self) { s in
                                Button { category = s } label: {
                                    Text(s).font(.calBody).foregroundStyle(Caliper.textPrimary)
                                        .padding(.horizontal, Caliper.space5)
                                        .frame(height: 32)
                                        .overlay(Rectangle().strokeBorder(
                                            s == category ? Caliper.textPrimary : Caliper.lineStrong,
                                            lineWidth: Caliper.borderWidth))
                                }
                                .buttonStyle(CaliperPressStyle())
                            }
                        }
                        .padding(.horizontal, Caliper.gutter)
                    }
                    .padding(.top, Caliper.space5)
                }
                Text("Leave it blank if the lot has one kind of card.")
                    .caliperMeta()
                    .padding(.horizontal, Caliper.gutter)
                    .padding(.top, Caliper.space5)
                if let error {
                    Text(error).caliperMeta(Caliper.confMid)
                        .padding(.horizontal, Caliper.gutter).padding(.top, Caliper.space4)
                }
                if onDelete != nil {
                    Button { confirmDelete = true } label: {
                        Text("Delete band").caliperLabel(Caliper.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Caliper.gutter)
                            .frame(minHeight: Caliper.hitMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CaliperPressStyle())
                    .padding(.top, Caliper.space6)
                }
            }
        } confirm: {
            CaliperButton(title: "Save", variant: .primary, fullWidth: true) {
                Task {
                    let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let failure = await onSave(trimmed.isEmpty ? nil : trimmed) { error = failure } else { dismiss() }
                }
            }
        }
        .onAppear { category = initial }
        .confirmationDialog("Delete this band?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete band", role: .destructive) {
                Task {
                    guard let onDelete else { return }
                    if let failure = await onDelete() { error = failure } else { dismiss() }
                }
            }
        } message: {
            Text("Its buckets stay in the lot, each on its own.")
        }
    }
}
