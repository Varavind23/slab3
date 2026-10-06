import SwiftUI
import SwiftData
import AVFoundation

/// Scan (README.md §2). Valid slab codes capture automatically so a sourcer can
/// move through a stack without stopping for a shutter or confirmation step.
struct ScanScreen: View {
    @Bindable var app: AppState
    /// So a card opened from Recent scans deletes through the same undo window as
    /// everywhere else.
    let pendingDeletes: PendingDeletionStore
    @Environment(\.modelContext) private var context
    @Query(sort: \Card.scannedAt, order: .reverse) private var cards: [Card]

    @State private var controller = ScanController()
    @State private var cameraAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var showManualEntry = false
    @State private var recentCardIDs: [UUID] = []
    /// The card opened from Recent scans. Pushing it stops the camera (the preview's
    /// onDisappear), and coming back restarts it.
    @State private var route: UUID?
    @State private var highlightedCardID: UUID?
    @State private var toast: ScanToast?
    @State private var toastTask: Task<Void, Never>?
    /// Auto-scan or tap-to-scan, remembered across launches.
    ///
    /// It is a way of WORKING rather than a session accident — a stack goes
    /// through on auto, a single card handed across a table goes through on tap —
    /// so it outlives the screen. It lives here and not in `AppState` because no
    /// other screen reads it; same call `CardDetailScreen` makes for the Card
    /// Ladder connection flag.
    @AppStorage("caliper_auto_scan") private var autoScan = true
    /// Every group, for the filing bar's target (`AppState.scanTargetId`, which is
    /// also the team's current lot — it lives in AppState so Teams can read it).
    @Query(sort: \Folder.createdAt, order: .reverse) private var groups: [Folder]
    @State private var showTargetSheet = false
    @AppStorage(PriceService.connectedKey) private var cardLadderConnected = false
    // Held and prepared: building a generator per scan adds a perceptible lag to
    // the first buzz, which in burst mode is every buzz.
    @State private var captureHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var duplicateHaptic = UINotificationFeedbackGenerator()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScanFilingBar(target: scanTarget, lot: scanLot, filedToday: filedToday,
                          // Only a CL lot needs the buyer's own Card Ladder account; a
                          // CY lot takes members without one (M3, claim_lot_scan v3).
                          needsCardLadder: scanLot?.valueBasis == .cl && !cardLadderConnected,
                          tap: {
                              // A lot's bar opens the lot on Teams — lots are chosen there.
                              if scanLot != nil {
                                  app.tabTouched = true
                                  app.teamsPath = []
                                  app.tab = .teams
                              } else {
                                  showTargetSheet = true
                              }
                          },
                          swap: { showTargetSheet = true })
                .padding(.horizontal, Caliper.gutter)
                .padding(.bottom, Caliper.space4)
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
        // The session is the authority while scanning, so the stored preference
        // has to reach it on every change — not only when the camera starts.
        .onChange(of: autoScan) { _, on in controller.autoScan = on }
        .sheet(isPresented: $showTargetSheet) {
            ScanTargetSheet(targetId: $app.scanTargetId, explicitNone: $app.scanTargetExplicitNone,
                            openTeams: app.visibleTabs.contains(.teams) ? {
                                showTargetSheet = false
                                app.tabTouched = true
                                app.tab = .teams
                            } : nil).presentationDetents([.large])
        }
        .sheet(isPresented: $showManualEntry) {
            ManualEntrySheet(
                add: { scan in add(scan, photo: nil) },
                addBatch: addBatch,
                isHeld: { CardLookup.existing($0, in: context) != nil }
            )
            .presentationDetents([.medium, .large])
        }
        // Tapping Scan while a card is open goes back to the camera.
        .onChange(of: app.tabReselected) { _, _ in route = nil }
        .navigationDestination(item: $route) { id in
            if let card = cards.first(where: { $0.localId == id }) {
                CardDetailScreen(card: card, app: app, pendingDeletes: pendingDeletes)
            }
        }
    }

    private var header: some View {
        ScreenHeader(
            context: "Today · \(todayCount) scans",
            title: "Scan",
            lens: $app.lens,
            lenses: app.availableLenses
        ) {
            Button { showManualEntry = true } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(Caliper.textSecondary)
                    .frame(width: 26, height: 26)
                    .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
            }
            .buttonStyle(CaliperPressStyle())
            .accessibilityLabel("Enter or paste cert numbers")
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
                // Dimmed while the scanner is holding on the slab just captured:
                // the guides are the thing the user is actually looking at, so
                // the state has to be visible there and not only in the copy.
                CornerBrackets()
                    .opacity(controller.isHolding ? 0.35 : 1)
                    .animation(Caliper.easeOut, value: controller.isHolding)
                shutterLabel
                if let toast { ScanToastView(toast: toast, lens: app.lens) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // The whole viewport is the shutter in tap-to-scan (Caliper §2), and
            // inert in auto-scan — where a tap that took another slab would be
            // the duplicate bug, by hand.
            .contentShape(Rectangle())
            .onTapGesture { tapToScan() }
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
                .onAppear {
                    controller.autoScan = autoScan
                    controller.start(
                        onScan: { scan, photo in add(scan, photo: photo) },
                        onMiss: { missed() }
                    )
                }
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
    ///
    /// It states which state the scanner is in, because two of them look identical
    /// from the outside: "holding on the slab you just scanned" and "not reading
    /// your slab". A user who reads the hold as a failure waves the slab about
    /// instead of lifting it away, which is the one thing that keeps the hold up.
    /// Tap-to-scan gets the design's original line (Caliper §2).
    private var shutterLabel: some View {
        VStack {
            Spacer()
            VStack(spacing: Caliper.space3) {
                Text(shutterHeadline)
                    .font(.sans(16, .semibold))
                    .foregroundStyle(Caliper.textPrimary)
                Text(shutterSubhead).caliperLabel(Caliper.textSecondary)
            }
            .padding(.bottom, Caliper.space8 * 1.5)
            .animation(Caliper.easeOut, value: controller.isHolding)
            .animation(Caliper.easeOut, value: autoScan)
        }
    }

    /// The chosen group, if it still exists and can still be filed into. A group
    /// deleted or turned into a team lot since reads as none, never as a stale name.
    private var scanTarget: Folder? {
        guard !app.scanTargetId.isEmpty else { return nil }
        return groups.first { group in
            guard group.localId.uuidString == app.scanTargetId, !group.archived else { return false }
            // A lot's group only while the lot is open — a closed lot takes nothing.
            // Until this launch has LOADED the lots (a cold start at a show with no
            // signal) the local group is trusted: dropping it would send every
            // scan to plain inventory, unclaimed, when the claim would simply queue.
            return LotFolders.isFileable(group, openLots: app.lots.openLotIds, lotsLoaded: app.lots.hasLoaded)
        }
    }

    /// Open lots by id — which lot groups can be scanned into right now.
    private var openLots: [UUID: Lot] {
        Dictionary(app.lots.lots.filter { $0.status == .active }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var scanLot: Lot? { scanTarget?.teamLotId.flatMap { openLots[$0] } }

    private var filedToday: Int {
        guard let id = scanTarget?.localId else { return 0 }
        return cards.filter { $0.folder?.localId == id && Calendar.current.isDateInToday($0.scannedAt) }.count
    }

    private var shutterHeadline: String {
        guard autoScan else { return "Tap to scan" }
        return controller.isHolding ? "Captured — lift it away" : "Hold code in frame"
    }

    private var shutterSubhead: String {
        guard autoScan, controller.isHolding else { return "PSA · CGC QR or barcode" }
        return "The next slab scans on its own"
    }

    /// Tap-to-scan only. In auto-scan the viewport is inert: the camera is already
    /// taking every slab it recognises, and a tap that took another would be the
    /// duplicate bug committed by hand.
    private func tapToScan() {
        guard !autoScan else { return }
        controller.capture()
    }

    /// A tap that found nothing readable. Auto-scan has no equivalent — nothing
    /// was asked of it, so silence was honest — but a tap is a question, and a
    /// question with no answer reads as a broken scanner.
    private func missed() {
        duplicateHaptic.notificationOccurred(.warning)
        show(.noCode)
    }

    // MARK: Recent scans

    private var recentScans: some View {
        VStack(spacing: Caliper.space4) {
            // Auto sits beside Torch because both are ways of working THIS stack,
            // flipped mid-session with the camera live — not settings you go to
            // another screen to change.
            HStack(spacing: Caliper.space4) {
                Text("Recent scans").caliperLabel()
                Spacer(minLength: Caliper.space4)
                Text("Auto").caliperLabel(Caliper.textTertiary)
                CaliperSwitch(isOn: $autoScan)
                    .accessibilityLabel("Auto scan")
                    .accessibilityValue(autoScan
                        ? "On. Slabs capture as the camera recognises them."
                        : "Off. Tap the viewport to scan.")
                Text("Torch").caliperLabel(Caliper.textTertiary)
                CaliperSwitch(isOn: $controller.torchOn)
                    .accessibilityLabel("Torch")
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
                            Button { tapped(card) } label: { RecentScanRow(card: card) }
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
        // A card deleted from its detail screen leaves this list with the undo
        // window, the same way it leaves Cards.
        return recentCardIDs.compactMap { byID[$0] }
            .filter { !pendingDeletes.pendingIDs.contains($0.localId) }
    }

    private func add(_ scan: CertScan, photo: Data?) {
        switch ingest(scan, photo: photo) {
        case .duplicate(let existing):
            duplicateHaptic.notificationOccurred(.warning)
            show(.duplicate(name: existing.displayTitle, cert: existing.certNumber))
            withAnimation(Caliper.easeOut) { highlightedCardID = existing.localId }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(Caliper.easeOut) { highlightedCardID = nil }
            }
        case .added(let card):
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
    }

    /// A pasted cert list (`ManualEntrySheet`). Every cert goes through the same
    /// `ingest` as a scan — duplicate check, filing, lot claim — but the batch gets
    /// ONE haptic and ONE summary toast, and its prices go through `PricePacer`
    /// rather than all at once (the burst that got bulk refresh removed).
    private func addBatch(_ scans: [CertScan]) {
        var added: [Card] = []
        var rows: [UUID] = []
        var held = 0
        // In PASTE order: filing queues each card's lot claim here, and the pacer
        // prices in this same order, so claim N waits on the price that is next up.
        // Reversed, the first claim waited on the LAST price — past its 30s wait on a
        // long list, which left it pending until the app next came forward.
        for scan in scans {
            switch ingest(scan, photo: nil) {
            case .added(let card): added.append(card); rows.append(card.localId)
            case .duplicate(let card): held += 1; rows.append(card.localId)
            }
        }
        guard !scans.isEmpty else { return }
        // Each ingest put its row first, which leaves the batch upside down. Read
        // top-down in Recent scans, the way it was pasted.
        let moved = Set(rows)
        withAnimation(Caliper.easeOut) {
            recentCardIDs.removeAll { moved.contains($0) }
            recentCardIDs.insert(contentsOf: rows, at: 0)
        }
        if added.isEmpty { duplicateHaptic.notificationOccurred(.warning) } else { captureHaptic.impactOccurred() }
        show(.batch(added: added.count, held: held))
        PricePacer.shared.enqueue(added.map(\.localId), in: context)
    }

    private enum Ingest {
        case added(Card)
        case duplicate(Card)
    }

    /// Insert and file one cert — the part a scan and a pasted list share. Says
    /// nothing to the user and starts no price work; the callers decide both.
    private func ingest(_ scan: CertScan, photo: Data?) -> Ingest {
        // A duplicate cert gets an amber readout and does NOT add a row.
        //
        // Asked of the STORE, not of `cards`. That query is a rendered value —
        // refreshed when SwiftUI updates this view — and this closure was handed
        // to the camera back at `onAppear`, so a card inserted a moment ago can be
        // missing from it. At burst cadence that gap is exactly where the second
        // read of one slab landed: it found nothing, inserted a second card, and
        // the slab appeared twice in Recent scans under a cyan "captured" readout
        // instead of the amber duplicate one (2026-09-15).
        if let existing = CardLookup.existing(scan, in: context) {
            bringToFront(existing)
            return .duplicate(existing)
        }
        let card = Card(scan: scan)
        // The camera capture is the FLOOR, not the goal: it means a row always
        // has a picture, and an official render replaces it if one exists.
        if let photo { card.setImage(photo, from: .camera) }
        context.insert(card)
        // The filing bar's group, if one is chosen. Through CardFiling like every
        // other path, so a team lot claims here too. The price refresh is marked
        // as started FIRST: the claim waits on it (the server buckets on the CL
        // Value it caches), and without the mark the claim could run before the
        // refresh begins and fetch Card Ladder a second time.
        if let scanTarget {
            if scanTarget.isTeamLot { card.pricesLoading = true }
            CardFiling.file([card], into: scanTarget, in: context)
        }
        withAnimation(Caliper.easeOut) { recentCardIDs.insert(card.localId, at: 0) }
        app.tabTouched = true   // scanning is using the app: never pull them away to Teams
        return .added(card)
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

    /// A row that failed to identify says "Tap to retry", so a tap retries it.
    /// Every other row opens the card, the same as a row in Cards (owner decision,
    /// 0.7 — a card you had just scanned could not be opened from here at all).
    private func tapped(_ card: Card) {
        switch card.lookupStatus {
        case .notFound, .unavailable, .needsConfirm: retry(card)
        case .resolved, .pending: route = card.localId
        }
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
                if card.lotClaimState != nil {
                    LotVerdictLabel(card: card)
                } else {
                    Text(detail).caliperLabel(statusColor)
                }
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
/// There was also a `.miss` case, deleted because nothing produced it: under
/// auto-scan the scanner either reads a cert or says nothing at all, and silence
/// was honest because nothing had been asked of it. Tap-to-scan asks — so
/// `.noCode` is that case earning its place back, for a tap with nothing readable
/// in frame (2026-09-16).
enum ScanToast {
    case captured(card: Card)
    case duplicate(name: String, cert: String)
    case noCode
    /// A pasted cert list: how many became cards, how many were already held.
    case batch(added: Int, held: Int)
}

/// Blurred scrim, hairline border, a 2pt coloured left edge — cyan for a capture,
/// amber for a cert already in inventory or a tap that found nothing. Holds 1.8s.
struct ScanToastView: View {
    let toast: ScanToast
    /// Only to decide whether the max-buy figure belongs here. The toast has never
    /// carried a price under a CL or CY lens and still doesn't — the Caliper spec
    /// asks for one, but building it for everyone is a change to the scan screen of
    /// every shipped build, and this is a gated pilot. Under max buy the figure is
    /// the point: it is the number he needs while the slab is still in his hand and
    /// the seller is standing there.
    var lens: PriceLens = .cl

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 0) {
                Rectangle().fill(edgeColor).frame(width: 2)
                VStack(alignment: .leading, spacing: Caliper.space3) {
                    HStack(alignment: .firstTextBaseline, spacing: Caliper.space4) {
                        Text(title)
                            .font(.calBody)
                            .foregroundStyle(Caliper.textPrimary)
                            .lineLimit(1)
                        if lens == .maxBuy, case .captured(let card) = toast {
                            Spacer(minLength: Caliper.space3)
                            // Fills in as the price fetch lands — the toast already
                            // re-reads the card while it resolves, so an em dash
                            // here becomes a figure without the toast being
                            // replaced.
                            MaxBuyLead(cents: MaxBuyValue.cents(for: card))
                        }
                    }
                    Text(subtitle).caliperLabel(edgeColor)
                    // The lot verdict, as it arrives. Usually after the toast has
                    // gone — the row keeps it (plan §7.2–7.3).
                    if case .captured(let card) = toast { LotVerdictLabel(card: card) }
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
        case .batch(let added, _): return added > 0 ? Caliper.cyan : Caliper.confMid
        case .duplicate, .noCode: return Caliper.confMid
        }
    }
    private var title: String {
        switch toast {
        case .captured(let card): return card.displayTitle
        case .duplicate(let name, _): return name
        case .noCode: return "No code in frame"
        case .batch(let added, _):
            return added == 0 ? "Nothing new added" : "Added \(added) \(added == 1 ? "card" : "cards")"
        }
    }
    /// Reads the card as it resolves, so "Identifying" becomes the real set and
    /// card number without the toast being replaced.
    private var subtitle: String {
        switch toast {
        case .captured(let card):
            return card.lookupStatus == .pending ? "Identifying · #\(card.certNumber)" : card.metaLine
        case .duplicate(_, let cert): return "Already in inventory · #\(cert)"
        case .noCode: return "Hold the label inside the guides"
        case .batch(let added, let held):
            var parts = held > 0 ? ["\(held) already in inventory"] : []
            if added > 0 { parts.append("Pricing one at a time") }
            return parts.joined(separator: " · ")
        }
    }
}
