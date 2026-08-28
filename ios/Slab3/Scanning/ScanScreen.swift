import SwiftUI
import SwiftData
import AVFoundation

/// Scan (README.md §2). Valid slab codes capture automatically so a sourcer can
/// move through a stack without stopping for a shutter or confirmation step.
struct ScanScreen: View {
    @Bindable var app: AppState
    @Environment(\.modelContext) private var context
    @Query(sort: \Card.scannedAt, order: .reverse) private var cards: [Card]

    @State private var controller = ScanController()
    @State private var cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var showManualEntry = false
    @State private var recentCardIDs: [UUID] = []
    @State private var highlightedCardID: UUID?
    @State private var toast: ScanToast?
    @State private var toastTask: Task<Void, Never>?
    // Held and prepared: building a generator per scan adds a perceptible lag to
    // the first buzz, which in burst mode is every buzz.
    @State private var captureHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var duplicateHaptic = UINotificationFeedbackGenerator()

    var body: some View {
        VStack(spacing: 0) {
            header
            viewport
                .padding(.horizontal, Caliper.gutter)
            recentScans
                .padding(.horizontal, Caliper.gutter)
                .padding(.top, Caliper.space5)
            Spacer(minLength: 0)
        }
        .background(Caliper.bg)
        .task {
            captureHaptic.prepare()
            duplicateHaptic.prepare()
            await ensureCameraAccess()
        }
        .sheet(isPresented: $showManualEntry) {
            ManualEntrySheet { scan in add(scan, photo: nil) }
                .presentationDetents([.height(320)])
        }
    }

    private var header: some View {
        ScreenHeader(
            context: "Today · \(todayCount) scans",
            title: "Scan",
            source: $app.activeSource
        ) {
            Button { showManualEntry = true } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(Caliper.textSecondary)
                    .frame(width: 26, height: 26)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
            }
            .buttonStyle(CaliperPressStyle())
            .accessibilityLabel("Enter a cert number by hand")
        }
    }

    // MARK: Viewport

    private var viewport: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0x0A / 255, green: 0x10 / 255, blue: 0x13 / 255),
                             Color(red: 0x07 / 255, green: 0x0A / 255, blue: 0x0C / 255)],
                    startPoint: .top, endPoint: .bottom
                )
                camera
                CornerBrackets()
                shutterLabel
                if let toast { ScanToastView(toast: toast) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
        }
        .aspectRatio(1.15, contentMode: .fit)
    }

    @ViewBuilder private var camera: some View {
        #if targetEnvironment(simulator)
        unavailable(
            "Camera scanning needs a real device",
            "The scanner uses the camera and can't run in the Simulator. Run Slabs on your iPhone to scan slabs."
        )
        #else
        if !cameraAuthorized {
            unavailable(
                "Camera access is off",
                "Enable camera access for Slabs to read cert barcodes.",
                action: ("Open Settings", { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } })
            )
        } else if let error = controller.scannerError {
            unavailable("Scanner unavailable", error)
        } else {
            CameraPreview(session: controller.captureSession)
                .onAppear { controller.start { scan, photo in add(scan, photo: photo) } }
                .onDisappear { controller.stop() }
        }
        #endif
    }

    private func unavailable(_ title: String, _ message: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: Caliper.space5) {
            Text(title).font(.calBody).foregroundStyle(Caliper.textPrimary)
            Text(message)
                .caliperMeta()
                .multilineTextAlignment(.center)
            if let action {
                CaliperButton(title: action.0, variant: .accent, action: action.1)
            }
        }
        .padding(Caliper.space8)
    }

    /// Anchored to the lower third of the viewport.
    private var shutterLabel: some View {
        VStack {
            Spacer()
            VStack(spacing: Caliper.space3) {
                Text("Hold code in frame")
                    .font(.sans(16, .semibold))
                    .foregroundStyle(Caliper.textPrimary)
                Text("PSA · CGC QR or barcode").caliperLabel(Caliper.textSecondary)
            }
            .padding(.bottom, Caliper.space8 * 1.5)
        }
    }

    // MARK: Recent scans

    private var recentScans: some View {
        VStack(spacing: Caliper.space4) {
            HStack {
                Text("Recent scans").caliperLabel()
                Spacer()
                Text("Torch").caliperLabel(Caliper.textTertiary)
                CaliperSwitch(isOn: $controller.torchOn)
            }
            .frame(height: Caliper.hitMin)

            if recentCards.isEmpty {
                Text("Scanned cards will appear here while the camera stays ready.")
                    .caliperMeta()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Caliper.space5)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: Caliper.space3) {
                        ForEach(recentCards.prefix(6)) { card in
                            Button { retry(card) } label: { RecentScanRow(card: card) }
                                .buttonStyle(.plain)
                                .overlay(Rectangle().strokeBorder(
                                    highlightedCardID == card.localId ? Caliper.confMid : Caliper.line,
                                    lineWidth: highlightedCardID == card.localId ? 2 : Caliper.borderWidth
                                ))
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// Indexed once per redraw. This used to be a `first(where:)` per row against
    /// the full card query, and every enrichment write redraws the screen — so
    /// the cost grew with the whole inventory while scanning.
    private var recentCards: [Card] {
        let byID = Dictionary(cards.map { ($0.localId, $0) }, uniquingKeysWith: { a, _ in a })
        return recentCardIDs.compactMap { byID[$0] }
    }

    private func add(_ scan: CertScan, photo: Data?) {
        // A duplicate cert gets an amber readout and does NOT add a row.
        if let existing = cards.first(where: { $0.grader == scan.grader && $0.certNumber == scan.certNumber }) {
            duplicateHaptic.notificationOccurred(.warning)
            bringToFront(existing)
            show(.duplicate(name: existing.displayTitle, cert: existing.certNumber))
            withAnimation(Caliper.easeOut) { highlightedCardID = existing.localId }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(Caliper.easeOut) { highlightedCardID = nil }
            }
            return
        }
        let card = Card(scan: scan)
        // The camera capture is the FLOOR, not the goal: it means a row always
        // has a picture, and an official render replaces it if one exists.
        if let photo { card.setImage(photo, from: .camera) }
        context.insert(card)
        withAnimation(Caliper.easeOut) { recentCardIDs.insert(card.localId, at: 0) }
        // A single tap, not the three-tap .success pattern — at burst cadence
        // that turns into mush.
        captureHaptic.impactOccurred()
        show(.captured(card: card))
        // Identity and price work run off the scan loop — the camera immediately
        // accepts the next slab while this row fills itself in.
        //
        // Card Ladder and Courtyard go FIRST. PSA is walled (spike/README.md §4a)
        // and fails slowly — up to 15s on its API plus 50s on the scraper — so
        // asking it first meant every row sat nameless for the length of a
        // timeout before the sources that can actually answer were even tried.
        // PSA still runs, and still outranks the others if it ever comes back.
        Task {
            await PriceService.refresh(card, in: context)
            await PsaIdentityService.enrich(card)
        }
    }

    /// Cancel-and-replace, never queue: in burst mode the toasts would otherwise
    /// run seconds behind the camera and describe a slab already back in the box.
    private func show(_ next: ScanToast) {
        toastTask?.cancel()
        withAnimation(Caliper.easeOut) { toast = next }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(Caliper.easeOut) { toast = nil }
        }
    }

    private func bringToFront(_ card: Card) {
        recentCardIDs.removeAll { $0 == card.localId }
        recentCardIDs.insert(card.localId, at: 0)
    }

    /// Tap-to-retry on an unresolved row. No longer PSA-only: Card Ladder
    /// resolves CGC certs too, so a CGC card is now worth retrying.
    private func retry(_ card: Card) {
        guard card.lookupStatus != .resolved else { return }
        card.lookupStatus = .pending
        Task {
            await PriceService.refresh(card, in: context, force: true)
            await PsaIdentityService.enrich(card)
        }
    }

    private var todayCount: Int {
        cards.filter { Calendar.current.isDateInToday($0.scannedAt) }.count
    }

    private func ensureCameraAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraAuthorized = true
        case .notDetermined: cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        default: cameraAuthorized = false
        }
    }
}

private struct RecentScanRow: View {
    let card: Card

    var body: some View {
        HStack(spacing: Caliper.space5) {
            SlabThumbnail(card: card)
            VStack(alignment: .leading, spacing: Caliper.space3) {
                Text(card.displayTitle)
                    .font(.calBody)
                    .foregroundStyle(Caliper.textPrimary)
                    .lineLimit(1)
                Text(detail).caliperLabel(statusColor)
            }
            Spacer(minLength: 0)
            if card.lookupStatus == .pending {
                ProgressView().tint(Caliper.cyan).controlSize(.small)
            } else {
                GradeBadge(grader: card.grader, grade: card.grade)
            }
        }
        .padding(.horizontal, Caliper.space4)
        .padding(.vertical, Caliper.space3)
        .background(Caliper.surface)
        .contentShape(Rectangle())
    }

    private var detail: String {
        switch card.lookupStatus {
        case .pending: return "Identifying · \(card.grader.rawValue.uppercased()) #\(card.certNumber)"
        case .resolved: return [card.set, "#\(card.certNumber)"].compactMap { $0 }.joined(separator: " · ")
        case .notFound: return "\(card.grader.rawValue.uppercased()) cert not found · Tap to retry"
        case .unavailable: return "\(card.grader.rawValue.uppercased()) couldn\'t be reached · Tap to retry"
        case .needsConfirm: return "Details pending · Tap to retry"
        }
    }

    private var statusColor: Color {
        switch card.lookupStatus {
        case .resolved: return Caliper.confHigh
        case .notFound, .needsConfirm, .unavailable: return Caliper.confMid
        case .pending: return Caliper.cyan
        }
    }
}

// MARK: - Viewport furniture

private struct CornerBrackets: View {
    var body: some View {
        GeometryReader { geo in
            ForEach(0..<4, id: \.self) { corner in
                bracket
                    .rotationEffect(.degrees(Double(corner) * 90))
                    .position(
                        x: corner == 0 || corner == 3 ? 16 + 12 : geo.size.width - 16 - 12,
                        y: corner < 2 ? 16 + 12 : geo.size.height - 16 - 12
                    )
            }
        }
    }
    private var bracket: some View {
        Path { p in
            p.move(to: CGPoint(x: 0, y: 24)); p.addLine(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 24, y: 0))
        }
        .stroke(Caliper.cyan, lineWidth: 2)
        .frame(width: 24, height: 24)
    }
}

// MARK: - Post-scan toast

/// What just happened, said once and briefly.
///
/// `.captured` used to carry a `started: Date` and render "Matched in 1.4s". That
/// was wrong twice over for a continuous scanner: nothing is matched at capture
/// time (identity and prices resolve afterwards), and reading `Date()` inside a
/// computed property renders one frozen number that then quietly goes stale. It
/// now holds the card and reads its live state instead — so the toast fills
/// itself in while it is still on screen, which is the point.
///
/// There was also a `.miss` case. Nothing produces it: the scanner either reads a
/// cert or says nothing at all, so it was deleted rather than given a fake caller.
enum ScanToast {
    case captured(card: Card)
    case duplicate(name: String, cert: String)
}

/// Blurred scrim, hairline border, a 2pt coloured left edge — cyan for a capture,
/// amber for a cert already in inventory. Holds 1.8s.
struct ScanToastView: View {
    let toast: ScanToast

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 0) {
                Rectangle().fill(edgeColor).frame(width: 2)
                VStack(alignment: .leading, spacing: Caliper.space3) {
                    Text(title)
                        .font(.calBody)
                        .foregroundStyle(Caliper.textPrimary)
                        .lineLimit(1)
                    Text(subtitle).caliperLabel(edgeColor)
                }
                .padding(Caliper.rowPad)
                Spacer(minLength: 0)
                if case .captured(let card) = toast {
                    GradeBadge(grader: card.grader, grade: card.grade)
                        .padding(.trailing, Caliper.rowPad)
                }
            }
            .background(.ultraThinMaterial)
            .overlay(Rectangle().strokeBorder(edgeColor.opacity(0.6), lineWidth: Caliper.borderWidth))
            .transition(.opacity)
        }
    }

    private var edgeColor: Color {
        switch toast {
        case .captured: return Caliper.cyan
        case .duplicate: return Caliper.confMid
        }
    }
    private var title: String {
        switch toast {
        case .captured(let card): return card.displayTitle
        case .duplicate(let name, _): return name
        }
    }
    /// Reads the card as it resolves, so "Identifying" becomes the real set and
    /// card number without the toast being replaced.
    private var subtitle: String {
        switch toast {
        case .captured(let card):
            return card.lookupStatus == .pending ? "Identifying · #\(card.certNumber)" : card.metaLine
        case .duplicate(_, let cert): return "Already in inventory · #\(cert)"
        }
    }
}

// MARK: - Manual entry

/// The pencil in the header. A slab whose label is too scuffed to read still has
/// to get into inventory.
struct ManualEntrySheet: View {
    let add: (CertScan) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cert = ""
    @State private var grader: Grader = .psa

    var body: some View {
        CaliperSheet(title: "Enter a cert") {
            Button("Cancel") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: Caliper.space6) {
                Picker("Grader", selection: $grader) {
                    Text("PSA").tag(Grader.psa)
                    Text("CGC").tag(Grader.cgc)
                }
                .pickerStyle(.segmented)

                TextField("Cert number", text: $cert)
                    .font(.price)
                    .keyboardType(.numberPad)
                    .foregroundStyle(Caliper.textPrimary)
                    .padding(.horizontal, Caliper.rowPad)
                    .frame(height: Caliper.hitMin)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
            }
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space6)
        } confirm: {
            CaliperButton(title: "Add card", variant: .primary, fullWidth: true, disabled: trimmed.isEmpty) {
                add(CertScan(grader: grader, certNumber: trimmed, raw: trimmed))
                dismiss()
            }
        }
    }

    private var trimmed: String { cert.trimmingCharacters(in: .whitespaces) }
}
