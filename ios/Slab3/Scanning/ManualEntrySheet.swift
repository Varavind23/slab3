import SwiftUI

/// The pencil in the Scan header. It started as one cert for a slab whose label is
/// too scuffed to read. It now also takes a pasted LIST, because a buyer is usually
/// sent a seller's certs to check, and used to enter them one at a time (owner ask,
/// 2026-10-01).
///
/// What the text holds is read live (`CertListParser`) into a preview, so the user
/// sees exactly which certs will become cards before anything is added:
///   • the grader is the camera's guess, and its chip flips it — a guess by length
///     can be wrong;
///   • a cert already in inventory is marked and adds nothing;
///   • past `CertBatch.cap` new certs, the rest stay in the field for the next add.
///
/// ONE cert behaves exactly as the sheet always did: `add`, the scan's own toast
/// and duplicate highlight, then dismiss. Two or more go to `addBatch`, which
/// prices them through `PricePacer` rather than all at once.
struct ManualEntrySheet: View {
    let add: (CertScan) -> Void
    let addBatch: ([CertScan]) -> Void
    /// Asked of the store (`CardLookup.existing`), never a `@Query` — see `ScanScreen.ingest`.
    let isHeld: (CertScan) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    /// Grader flips, by cert number — kept across an add, so overflow keeps them.
    @State private var overrides: [String: Grader] = [:]
    @State private var excluded: Set<String> = []
    @FocusState private var focused: Bool

    /// `text` pre-fills the field — the render tests use it.
    init(add: @escaping (CertScan) -> Void, addBatch: @escaping ([CertScan]) -> Void,
         isHeld: @escaping (CertScan) -> Bool, text: String = "") {
        self.add = add
        self.addBatch = addBatch
        self.isHeld = isHeld
        _text = State(initialValue: text)
    }

    var body: some View {
        let scans = Self.scans(in: text, overrides: overrides, excluded: excluded)
        let split = CertBatch.split(scans, isHeld: isHeld)
        CaliperSheet(title: "Enter certs") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: Caliper.space6) {
                field
                if !scans.isEmpty {
                    CertPreview(scans: scans, split: split, overrides: $overrides, excluded: $excluded)
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No cert numbers found").caliperMeta(Caliper.confMid)
                }
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space6)
        } confirm: {
            VStack(spacing: Caliper.space4) {
                if !split.over.isEmpty {
                    Text("\(CertBatch.cap) per add · \(split.over.count) stay here for the next one")
                        .caliperMeta(Caliper.textTertiary)
                }
                CaliperButton(title: Self.confirmTitle(scans: scans, split: split), variant: .primary,
                              fullWidth: true, disabled: scans.isEmpty || (scans.count > 1 && split.add.isEmpty)) {
                    confirm(scans, split: split)
                }
            }
        }
        .onAppear { focused = true }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: Caliper.space4) {
            TextField("Cert number, or paste a list", text: $text, axis: .vertical)
                .lineLimit(3...8)
                .font(.price)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .foregroundStyle(Caliper.textPrimary)
                .padding(Caliper.rowPad)
                .frame(minHeight: Caliper.hitMin)
                .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
            // The system paste control, so pasting a list never raises iOS's
            // "allow paste" prompt.
            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first else { return }
                Task { @MainActor in
                    text = text.isEmpty ? pasted : text + "\n" + pasted
                }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.roundedRectangle(radius: Caliper.radiusControl))
            .tint(Caliper.surface2)
        }
    }

    private func confirm(_ scans: [CertScan], split: CertBatch.Split) {
        if scans.count == 1 {
            add(scans[0])
            dismiss()
            return
        }
        let over = Set(split.over.map(\.certNumber))
        addBatch(scans.filter { !over.contains($0.certNumber) })
        if split.over.isEmpty {
            dismiss()
        } else {
            text = split.over.map(\.certNumber).joined(separator: "\n")
        }
    }

    // MARK: Pure parts (tested in CertListParserTests)

    enum Status: Equatable {
        case add, held, over
        var note: String? {
            switch self {
            case .add: nil
            case .held: "In inventory"
            case .over: "Next add"
            }
        }
    }

    static func scans(in text: String, overrides: [String: Grader], excluded: Set<String>) -> [CertScan] {
        CertListParser.extract(text)
            .filter { !excluded.contains($0.certNumber) }
            .map { scan in
                guard let grader = overrides[scan.certNumber], grader != scan.grader else { return scan }
                return CertScan(grader: grader, certNumber: scan.certNumber, raw: scan.raw)
            }
    }

    static func status(of scan: CertScan, in split: CertBatch.Split) -> Status {
        if split.held.contains(scan) { return .held }
        if split.over.contains(scan) { return .over }
        return .add
    }

    static func summary(scans: [CertScan], split: CertBatch.Split) -> String {
        var parts = ["\(scans.count) \(scans.count == 1 ? "cert" : "certs")"]
        if !split.held.isEmpty { parts.append("\(split.held.count) in inventory") }
        return parts.joined(separator: " · ")
    }

    /// States the outcome with its count, like every Caliper sheet's confirm.
    static func confirmTitle(scans: [CertScan], split: CertBatch.Split) -> String {
        if scans.count <= 1 { return "Add card" }
        if split.add.isEmpty { return "Nothing new to add" }
        if !split.over.isEmpty { return "Add first \(split.add.count)" }
        return "Add \(split.add.count) \(split.add.count == 1 ? "card" : "cards")"
    }
}

/// The live list under the field — its own view so the render tests can draw it
/// (ImageRenderer does not draw a ScrollView's contents).
struct CertPreview: View {
    let scans: [CertScan]
    let split: CertBatch.Split
    @Binding var overrides: [String: Grader]
    @Binding var excluded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(ManualEntrySheet.summary(scans: scans, split: split))
                .caliperLabel(Caliper.textTertiary)
                .padding(.bottom, Caliper.space4)
            ForEach(scans, id: \.certNumber) { scan in
                row(scan, status: ManualEntrySheet.status(of: scan, in: split))
                Rectangle().fill(Caliper.line).frame(height: Caliper.borderWidth)
            }
        }
    }

    private func row(_ scan: CertScan, status: ManualEntrySheet.Status) -> some View {
        HStack(spacing: Caliper.space5) {
            Button {
                overrides[scan.certNumber] = scan.grader == .psa ? .cgc : .psa
            } label: {
                Chip(text: scan.grader.rawValue.uppercased(), size: .tap)
                    .frame(width: 52, alignment: .leading)
                    .frame(minHeight: Chip.Size.tap.hitHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CaliperPressStyle())
            .accessibilityLabel("Grader \(scan.grader.rawValue.uppercased()), tap to switch")

            Text(scan.certNumber)
                .font(.price)
                .foregroundStyle(status == .add ? Caliper.textPrimary : Caliper.textTertiary)
            Spacer(minLength: Caliper.space4)
            if let note = status.note {
                Text(note).caliperMeta(status == .held ? Caliper.confMid : Caliper.textTertiary)
            }
            Button {
                excluded.insert(scan.certNumber)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Caliper.textSecondary)
                    .frame(width: Caliper.hitMin, height: Caliper.hitMin)
                    .contentShape(Rectangle())
            }
            .buttonStyle(CaliperPressStyle())
            .accessibilityLabel("Remove \(scan.certNumber)")
        }
    }

}
