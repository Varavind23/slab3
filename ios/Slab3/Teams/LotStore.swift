import Foundation
import Observation
import SwiftData
import Supabase

/// A lot: one allocation the team buys into, with a deadline. Mirrors `lots`.
struct Lot: Identifiable, Equatable, Decodable {
    let id: UUID
    var name: String
    var deadline: Date?
    var status: LotStatus
    let createdAt: Date
    /// The lead's warning line across the top of the lot ("Only accepting PSA
    /// slabs"). Free text; nil shows no banner.
    var banner: String? = nil
    /// What this lot's money is counted in (ValueBasis). Changed only through
    /// `set_lot_basis` — the server refuses a plain update.
    var valueBasis: ValueBasis = .cl
    /// Set when a lead archived it (2026-10-01): team-wide, and always closed. It
    /// leaves the Teams list for an "Archived · N" section but keeps its local group,
    /// its buys and its Team activity — archive is how a lot with buys goes away.
    var archivedAt: Date? = nil

    var isArchived: Bool { archivedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, deadline, status, banner, createdAt = "created_at", valueBasis = "value_basis"
        case archivedAt = "archived_at"
    }
}

extension Lot {
    /// In an extension so the memberwise init survives. `value_basis` arrives from
    /// 0.9's migration on; absent reads as CL, which is what every lot was before it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        status = try c.decode(LotStatus.self, forKey: .status)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        banner = try c.decodeIfPresent(String.self, forKey: .banner)
        valueBasis = try c.decodeIfPresent(ValueBasis.self, forKey: .valueBasis) ?? .cl
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }
}

extension Lot {
    /// Open lots in the order a buyer works them: soonest deadline first, then the
    /// ones with no deadline, newest first. Used by Teams and Team activity alike.
    static func soonestFirst(_ a: Lot, _ b: Lot) -> Bool {
        switch (a.deadline, b.deadline) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.createdAt > b.createdAt
        }
    }
}

/// One slab in a lot, as every teammate's phone sees it — the row a buyer draws
/// for a card that is not in their OWN inventory (plan §7.5), and the lead's
/// whole-lot export. Display fields were frozen at claim time on the server.
struct TeamClaim: Identifiable, Equatable, Decodable {
    let id: UUID
    let lotId: UUID
    let rangeId: UUID?
    let cert: String
    let grader: String
    let gradeLabel: String?
    let priceCents: Int?
    let clConfidence: Int?
    let label: String?
    let player: String?
    let cardSet: String?
    let cardYear: String?
    let cardNumber: String?
    let imageUrl: String?
    let buyerId: UUID
    let state: String
    let scannedAt: String
    /// Courtyard's value at claim (0.9). `priceCents` stays CL Value at claim on
    /// every claim, whatever the lot's basis — see `value(in:)`.
    var cyPriceCents: Int? = nil
    var cyConfidence: Int? = nil
    /// What the buyer's phone showed as max buy when it claimed. Display only: the
    /// server never decides anything on it. nil on claims from before 0.9.
    var maxBuyCents: Int? = nil
    /// The person this slab is credited to (V1, 2026-10-04): they are its buyer
    /// everywhere; `buyerId` is who added it. nil = the scanner is the buyer.
    /// Resolve through `BuyerResolver`, never by reading `buyerId` for a name.
    var creditedPersonId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case id, cert, grader, label, player, state
        case lotId = "lot_id", rangeId = "lot_buy_range_id", gradeLabel = "grade_label"
        case priceCents = "price_cents", clConfidence = "cl_confidence", cardSet = "card_set"
        case cardYear = "card_year", cardNumber = "card_number", imageUrl = "image_url"
        case buyerId = "buyer_id", scannedAt = "scanned_at"
        case cyPriceCents = "cy_price_cents", cyConfidence = "cy_confidence", maxBuyCents = "max_buy_cents"
        case creditedPersonId = "credited_person_id"
    }

    /// The claim's value in a lot basis. nil is a real answer — that source had no
    /// value for the slab — and renders as an em dash, never $0.
    func value(in basis: ValueBasis) -> Int? { basis == .cl ? priceCents : cyPriceCents }

    /// The figure a Team activity view reads (MAX · CL · CY, owner M6).
    func cents(in lens: PriceLens) -> Int? {
        switch lens {
        case .maxBuy: maxBuyCents
        case .cl: priceCents
        case .cy: cyPriceCents
        }
    }

    var isOverLimit: Bool { state == "over_limit" }
    var scannedDate: Date? { ISO8601.date(scannedAt) }
    /// The long assembled title, or the player — whichever CL gave.
    var title: String { label ?? player ?? "#\(cert)" }
}

/// What the lot's BUYER says it has accepted for one bucket — typed in by a lead,
/// timestamped. Never merged with what the team has bought (teams.md §8).
struct RangeReport: Equatable, Decodable {
    let rangeId: UUID
    let usedCents: Int64
    let cardCount: Int?
    let reportedAt: String
    enum CodingKeys: String, CodingKey {
        case rangeId = "lot_buy_range_id", usedCents = "used_cents", cardCount = "card_count", reportedAt = "reported_at"
    }
    var reportedDate: Date? { ISO8601.date(reportedAt) }
}

/// What the team has bought into one bucket: confirmed claims only, counted in the
/// lot's CURRENT basis (the server's view follows it).
struct RangeUsage: Equatable, Decodable {
    let rangeId: UUID?
    let cards: Int
    let usedCents: Int64
    /// How many of `cards` have a value in the lot's basis. After a lead switches a
    /// lot, a slab the new source cannot value keeps its slot but adds no dollars.
    var valuedCards: Int? = nil
    enum CodingKeys: String, CodingKey {
        case rangeId = "lot_buy_range_id", cards, usedCents = "used_cents", valuedCards = "valued_cards"
    }
}

enum LotStatus: String, Codable, Equatable, CaseIterable {
    /// Being set up by a lead — invisible to buyers, takes no claims.
    case draft
    /// Open for buying.
    case active
    /// Submitted or finished — visible, takes no claims.
    case closed
}

/// The team's lots, their buy ranges, and the range library. Server-authoritative
/// (plan §1): every read is a fetch and every write a request; nothing here is the
/// source of truth for anything. Reads are open to any member, writes to leads —
/// RLS enforces that on the server, so the lead-only UI is courtesy, not security.
///
/// Inert unless `TeamsFeature.isAvailable` AND the user is on a team.
@MainActor
@Observable
final class LotStore {
    private(set) var lots: [Lot] = []
    private(set) var rangesByLot: [UUID: [BuyRange]] = [:]
    private(set) var library: [BuyRange] = []
    /// Keyed by range id. A range with no entry has bought nothing yet.
    private(set) var usage: [UUID: RangeUsage] = [:]
    /// Every live slab (confirmed + over-limit) in each lot, all buyers.
    private(set) var claimsByLot: [UUID: [TeamClaim]] = [:]
    /// The latest reported figure per bucket; absent = never reported.
    private(set) var reports: [UUID: RangeReport] = [:]
    /// When the last SUCCESSFUL load started — a claim confirmed after this may
    /// legitimately be missing from `claimsByLot` (LotClaims.reconcile).
    private(set) var loadedAt: Date?
    /// The team `lots` was loaded FOR. Set with `loadedAt`, before `lots` is
    /// published, so a reader never sees one team's lot list stamped as another's
    /// (TeamSync.shouldSyncGroups).
    private(set) var loadedTeamId: UUID?
    private(set) var isWorking = false

    func ranges(for lot: Lot) -> [BuyRange] { rangesByLot[lot.id] ?? [] }
    /// The lots that take cards right now — the ONE list every "can this group be
    /// filed into?" asks (LotFolders.isFileable), so Scan, the detail screen and the
    /// Group sheet can never disagree.
    var openLotIds: Set<UUID> { Set(lots.filter { $0.status == .active }.map(\.id)) }
    /// The launch value is not an answer: until lots have loaded, lot groups are trusted.
    var hasLoaded: Bool { loadedAt != nil }
    func claims(for lot: Lot) -> [TeamClaim] { claimsByLot[lot.id] ?? [] }

    /// What this member should see: a buyer never sees a lead's unfinished draft.
    func visibleLots(isLead: Bool) -> [Lot] {
        LotFolders.visible(lots, isLead: isLead)
    }

    // MARK: Load

    /// One load at a time per team: launch, the app coming forward, the team id
    /// appearing and a claim landing can all ask at once, and each load is six
    /// requests. A second ask for the same team joins the one already running.
    func load(teamId: UUID?) async {
        guard TeamsFeature.isAvailable else { return }
        if let running = inFlight, running.teamId == teamId {
            await running.task.value
            return
        }
        let token = UUID()
        let task = Task { await self.performLoad(teamId: teamId) }
        inFlight = (token, teamId, task)
        await task.value
        if inFlight?.token == token { inFlight = nil }
    }
    private var inFlight: (token: UUID, teamId: UUID?, task: Task<Void, Never>)?

    /// Below the server's `max_rows`, so a full page always means "ask again".
    static let claimPage = 500

    private func performLoad(teamId: UUID?) async {
        guard let teamId else {
            // Not on a team is a real, loaded answer: the stamp says so, which is
            // what lets a group sync detach the lot groups of a team just left.
            loadedAt = Date(); loadedTeamId = nil
            lots = []; rangesByLot = [:]; library = []; usage = [:]
            claimsByLot = [:]; reports = [:]
            MaxBuyTeamPolicy.shared.basisByLot = [:]
            MaxBuyTeamPolicy.shared.remember()
            return
        }
        let started = Date()
        do {
            let lots: [Lot] = try await Backend.client.from("lots")
                .select("id, name, deadline, status, banner, created_at, value_basis, archived_at")
                .eq("team_id", value: teamId).order("created_at", ascending: false)
                .execute().value
            var byLot: [UUID: [BuyRange]] = [:]
            var usage: [UUID: RangeUsage] = [:]
            var claims: [UUID: [TeamClaim]] = [:]
            var reports: [UUID: RangeReport] = [:]
            if !lots.isEmpty {
                let ids = lots.map(\.id)
                let ranges: [LotRangeRow] = try await Backend.client.from("lot_buy_ranges")
                    .select().in("lot_id", values: ids)
                    .order("sort_order").execute().value
                for row in ranges { byLot[row.lotId, default: []].append(row.range) }
                let used: [RangeUsage] = try await Backend.client.from("lot_range_usage")
                    .select("lot_buy_range_id, cards, used_cents, valued_cards").in("lot_id", values: ids)
                    .execute().value
                for row in used { if let id = row.rangeId { usage[id] = row } }
                // Paged: PostgREST stops at `max_rows` (1000) without an error, and
                // `LotClaims.reconcile` reads a missing claim as "a lead released
                // it" — a short list would pull held cards out of their lots.
                var live: [TeamClaim] = []
                while true {
                    let page: [TeamClaim] = try await Backend.client.from("lot_claims")
                        .select("id, lot_id, lot_buy_range_id, cert, grader, grade_label, price_cents, cl_confidence, cy_price_cents, cy_confidence, max_buy_cents, credited_person_id, label, player, card_set, card_year, card_number, image_url, buyer_id, state, scanned_at")
                        .in("lot_id", values: ids).in("state", values: ["confirmed", "over_limit"])
                        .order("scanned_at", ascending: false).order("id")
                        .range(from: live.count, to: live.count + Self.claimPage - 1)
                        .execute().value
                    live += page
                    if page.count < Self.claimPage { break }
                }
                for claim in live { claims[claim.lotId, default: []].append(claim) }
                let rangeIds = byLot.values.flatMap { $0.map(\.id) }
                if !rangeIds.isEmpty {
                    let rows: [RangeReport] = try await Backend.client.from("lot_range_reports")
                        .select("lot_buy_range_id, used_cents, card_count, reported_at")
                        .in("lot_buy_range_id", values: rangeIds)
                        .order("reported_at", ascending: false).execute().value
                    for row in rows where reports[row.rangeId] == nil { reports[row.rangeId] = row }
                }
            }
            let library: [BuyRange] = try await Backend.client.from("buy_range_templates")
                .select().eq("team_id", value: teamId).order("name").execute().value
            // Stamp FIRST: MainShell's group sync reads the stamp when `lots` changes.
            loadedAt = started
            loadedTeamId = teamId
            // Assign only on change: MainShell syncs the lot groups when `lots`
            // changes, and a no-op reload should not touch the store.
            if self.lots != lots { self.lots = lots }
            // Max buy prices a card in a CY lot on Courtyard alone (MaxBuyValue).
            let bases = Dictionary(lots.map { ($0.id, $0.valueBasis) }, uniquingKeysWith: { a, _ in a })
            if MaxBuyTeamPolicy.shared.basisByLot != bases {
                MaxBuyTeamPolicy.shared.basisByLot = bases
                MaxBuyTeamPolicy.shared.remember()   // for a launch with no signal
            }
            if self.rangesByLot != byLot { self.rangesByLot = byLot }
            if self.library != library { self.library = library }
            if self.usage != usage { self.usage = usage }
            if self.claimsByLot != claims { self.claimsByLot = claims }
            if self.reports != reports { self.reports = reports }
        } catch {
            // Keep what we had. A lot view with yesterday's numbers beats a blank one,
            // and nothing about scanning waits on this.
        }
    }

    /// Fill the store without a server — render tests and previews only.
    func seedForPreview(lots: [Lot], ranges: [UUID: [BuyRange]],
                        usage: [UUID: RangeUsage], reports: [UUID: RangeReport] = [:],
                        claims: [UUID: [TeamClaim]] = [:], loadedAt: Date? = nil, teamId: UUID? = nil) {
        self.loadedAt = loadedAt; loadedTeamId = teamId
        self.lots = lots; rangesByLot = ranges; self.usage = usage
        self.reports = reports; claimsByLot = claims
    }

    // MARK: Live totals (plan §6: Realtime)

    private var live: RealtimeChannelV2?
    private var liveTask: Task<Void, Never>?

    /// Subscribe to claim changes for the team's lots. Realtime honours
    /// lot_claims' read policy, so only this team's rows arrive. Every change
    /// re-reads the lot figures — cheap, and it keeps ONE code path for what the
    /// dashboard shows. Claims are still decided on the server; this is display.
    func startLive(teamId: UUID) async {
        guard TeamsFeature.isAvailable else { return }
        if live != nil {
            // Already listening for THIS team; a different team (left one, joined
            // another between two loads) must not keep reloading the old team's lots.
            guard liveTeamId != teamId else { return }
            await stopLive()
        }
        let channel = Backend.client.channel("lot-claims-\(teamId.uuidString)")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "lot_claims")
        live = channel
        liveTeamId = teamId
        liveTask = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.requestReload(teamId: teamId)
            }
        }
        try? await channel.subscribeWithError()
    }

    /// Coalesce reloads: every claim, release and realtime event asks for one, and a
    /// bulk file of N cards would otherwise run 2N full reloads of six requests each.
    /// The last ask within the window wins.
    func requestReload(teamId: UUID) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, let self else { return }
            await self.load(teamId: teamId)
        }
    }
    private var reloadTask: Task<Void, Never>?

    private var liveTeamId: UUID?

    func stopLive() async {
        liveTeamId = nil
        liveTask?.cancel(); liveTask = nil
        if let live { await Backend.client.removeChannel(live) }
        live = nil
    }

    // MARK: Reported figures + lead release

    /// Record what the lot's buyer says it accepted for a bucket (leads).
    func addReport(rangeId: UUID, usedCents: Int64, cardCount: Int?, teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            try await Backend.client.from("lot_range_reports")
                .insert(ReportInsert(rangeId: rangeId, usedCents: usedCents, cardCount: cardCount)).execute()
        }
    }

    /// A lead drops a slab from the lot — a teammate's buy, or an over-limit one.
    func release(_ claim: TeamClaim, teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            try await Backend.client.rpc("release_lot_claim", params: [
                "p_lot_id": claim.lotId.uuidString, "p_cert": claim.cert, "p_grader": claim.grader,
            ]).execute()
        }
    }

    /// Credit slabs in a lot to a person, or back to whoever scanned them (nil) —
    /// the lead's Tag action in a receipt (V2). Closed and archived lots too: it is
    /// record-keeping, not buying.
    func setPerson(_ personId: UUID?, claims: [TeamClaim], lotId: UUID, teamId: UUID) async -> String? {
        struct Params: Encodable {
            let p_lot_id: UUID
            let p_claim_ids: [UUID]
            let p_person_id: UUID?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_lot_id, forKey: .p_lot_id)
                try c.encode(p_claim_ids, forKey: .p_claim_ids)
                try c.encode(p_person_id, forKey: .p_person_id)   // nil → JSON null, which clears
            }
            enum CodingKeys: String, CodingKey { case p_lot_id, p_claim_ids, p_person_id }
        }
        return await perform(teamId: teamId) {
            try await Backend.client.rpc("set_claim_person", params: Params(
                p_lot_id: lotId, p_claim_ids: claims.map(\.id), p_person_id: personId)).execute()
        }
    }

    // MARK: Library (leads)

    func saveTemplate(_ fields: BuyRangeFields, id: UUID?, teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            if let id {
                try await Backend.client.from("buy_range_templates").update(fields).eq("id", value: id).execute()
            } else {
                try await Backend.client.from("buy_range_templates")
                    .insert(TemplateInsert(teamId: teamId, fields: fields)).execute()
            }
        }
    }

    func deleteTemplate(_ id: UUID, teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            try await Backend.client.from("buy_range_templates").delete().eq("id", value: id).execute()
        }
    }

    // MARK: Lots (leads)

    /// Creates a DRAFT lot and returns its id — buyers see nothing until it opens.
    func createLot(name: String, deadline: Date?, banner: String? = nil,
                   teamId: UUID) async -> (id: UUID?, error: String?) {
        let id = UUID()
        let failure = await perform(teamId: teamId) {
            try await Backend.client.from("lots")
                .insert(LotInsert(id: id, teamId: teamId, name: name, deadline: deadline, banner: banner)).execute()
        }
        return failure.map { (nil, $0) } ?? (id, nil)
    }

    func updateLot(_ id: UUID, name: String, deadline: Date?, banner: String?, status: LotStatus,
                   teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            try await Backend.client.from("lots")
                .update(LotUpdate(name: name, deadline: deadline, banner: banner, status: status))
                .eq("id", value: id).execute()
        }
    }

    /// A lot with no buys, in any state. One with buys is ARCHIVED instead — the
    /// server enforces that too (`lots_delete_guard`, `has_buys`), since before 0.9
    /// only this phone-side check stood between a lead and a cascade of the team's
    /// claims.
    func delete(_ lot: Lot, teamId: UUID) async -> String? {
        guard claims(for: lot).isEmpty else { return TeamError.copy(for: "has_buys") }
        return await perform(teamId: teamId) {
            try await Backend.client.from("lots").delete().eq("id", value: lot.id).execute()
        }
    }

    /// Lead only, team-wide. Archiving an open lot closes it in the same write, so a
    /// buyer can never file into a lot nobody can see.
    func archive(_ lot: Lot, teamId: UUID) async -> String? {
        struct Archive: Encodable { let status: LotStatus; let archived_at: Date }
        return await perform(teamId: teamId) {
            try await Backend.client.from("lots")
                .update(Archive(status: lot.status == .draft ? .draft : .closed, archived_at: Date()))
                .eq("id", value: lot.id).execute()
        }
    }

    /// Back into the list as it was — closed stays closed; the lead reopens it if
    /// they mean to.
    func unarchive(_ lot: Lot, teamId: UUID) async -> String? {
        struct Unarchive: Encodable {
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encodeNil(forKey: .archivedAt)
            }
            enum CodingKeys: String, CodingKey { case archivedAt = "archived_at" }
        }
        return await perform(teamId: teamId) {
            try await Backend.client.from("lots").update(Unarchive()).eq("id", value: lot.id).execute()
        }
    }

    // MARK: A lot's ranges (leads)

    /// Adds a range to a lot as a COPY (so later library edits never move a live
    /// lot's goalposts); `saveToLibrary` also files the same criteria as a template.
    func addRange(_ fields: BuyRangeFields, to lotId: UUID,
                  fromTemplate templateId: UUID?, saveToLibrary: Bool, teamId: UUID) async -> String? {
        let order = (rangesByLot[lotId]?.compactMap(\.sortOrder).max() ?? -1) + 1
        return await perform(teamId: teamId) {
            var source = templateId
            if saveToLibrary && templateId == nil {
                let saved: [IdRow] = try await Backend.client.from("buy_range_templates")
                    .insert(TemplateInsert(teamId: teamId, fields: fields), returning: .representation)
                    .select("id").execute().value
                source = saved.first?.id
            }
            try await Backend.client.from("lot_buy_ranges")
                .insert(LotRangeInsert(id: UUID(), lotId: lotId, templateId: source, sortOrder: order,
                                       fields: fields))
                .execute()
        }
    }

    func updateRange(_ id: UUID, fields: BuyRangeFields, teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            try await Backend.client.from("lot_buy_ranges").update(fields).eq("id", value: id).execute()
        }
    }

    func deleteRange(_ id: UUID, teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            try await Backend.client.from("lot_buy_ranges").delete().eq("id", value: id).execute()
        }
    }

    // MARK: A lot's value basis (0.9, owner M4/M5)

    /// What `set_lot_basis` says a switch does — or did. Nothing is moved either way:
    /// claims keep their buckets, and a slab the new source cannot value keeps its
    /// slot and adds no dollars.
    struct BasisImpact: Decodable, Equatable {
        let claims: Int
        let noValue: Int
        let outsideRange: Int
        let overBudget: Int
        let changed: Bool
        enum CodingKeys: String, CodingKey {
            case claims, changed, noValue = "no_value", outsideRange = "outside_range", overBudget = "over_budget"
        }
    }

    /// The preview (`commit: false`, which writes nothing) and the switch itself go
    /// through the SAME server function, so the sheet shows exactly what it does.
    func switchBasis(_ lotId: UUID, to basis: ValueBasis, commit: Bool,
                     teamId: UUID) async -> (impact: BasisImpact?, error: String?) {
        struct Params: Encodable { let p_lot_id: UUID; let p_basis: String; let p_commit: Bool }
        guard TeamsFeature.isAvailable else { return (nil, TeamError.copy(for: "unavailable")) }
        do {
            let data = try await Backend.client.rpc("set_lot_basis", params: Params(
                p_lot_id: lotId, p_basis: basis.rawValue, p_commit: commit)).execute().data
            let impact = try JSONDecoder().decode(BasisImpact.self, from: data)
            if commit { await load(teamId: teamId) }
            return (impact, nil)
        } catch let error as PostgrestError {
            return (nil, TeamError.copy(for: error.message))
        } catch {
            return (nil, TeamError.copy(for: "network"))
        }
    }

    // MARK: The lot builder (one screen, one save)

    /// Run the builder's changes in order and reload ONCE at the end — `perform`
    /// reloads after every write, which for a lot of ten buckets is ten full reloads.
    /// Stops at the first failure; what landed stays landed, and because every
    /// bucket carries its own id a retry applies only what is missing.
    func apply(_ ops: [LotBuilderDraft.Op], teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            for op in ops {
                switch op {
                case let .createLot(id, name, deadline, banner, basis):
                    try await Backend.client.from("lots")
                        .insert(LotInsert(id: id, teamId: teamId, name: name, deadline: deadline, banner: banner,
                                          basis: basis))
                        .execute()
                case let .updateLot(id, name, deadline, banner, status):
                    try await Backend.client.from("lots")
                        .update(LotUpdate(name: name, deadline: deadline, banner: banner, status: status))
                        .eq("id", value: id).execute()
                case let .addRange(id, lotId, templateId, sortOrder, fields):
                    try await Backend.client.from("lot_buy_ranges")
                        .insert(LotRangeInsert(id: id, lotId: lotId, templateId: templateId, sortOrder: sortOrder,
                                               fields: fields))
                        .execute()
                case let .updateRange(id, sortOrder, fields):
                    try await Backend.client.from("lot_buy_ranges")
                        .update(RangeUpdate(sortOrder: sortOrder, fields: fields)).eq("id", value: id).execute()
                case let .deleteRange(id):
                    try await Backend.client.from("lot_buy_ranges").delete().eq("id", value: id).execute()
                }
            }
        }
    }

    private struct RangeUpdate: Encodable {
        let sortOrder: Int
        let fields: BuyRangeFields
        enum CodingKeys: String, CodingKey { case sortOrder = "sort_order" }
        func encode(to encoder: Encoder) throws {
            try fields.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sortOrder, forKey: .sortOrder)
        }
    }

    private func perform(teamId: UUID, _ work: () async throws -> Void) async -> String? {
        guard TeamsFeature.isAvailable else { return TeamError.copy(for: "unavailable") }
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            await load(teamId: teamId)
            return nil
        } catch let error as PostgrestError {
            // RLS refusals arrive as 42501 with no message of ours.
            return TeamError.copy(for: error.code == "42501" ? "not_lead" : error.message)
        } catch {
            return TeamError.copy(for: "network")
        }
    }

    // MARK: Wire shapes

    private struct LotRangeRow: Decodable {
        let lotId: UUID
        let range: BuyRange
        enum CodingKeys: String, CodingKey { case lotId = "lot_id" }
        init(from decoder: Decoder) throws {
            lotId = try decoder.container(keyedBy: CodingKeys.self).decode(UUID.self, forKey: .lotId)
            range = try BuyRange(from: decoder)
        }
    }
    private struct IdRow: Decodable { let id: UUID }

    private struct TemplateInsert: Encodable {
        let teamId: UUID
        let fields: BuyRangeFields
        enum CodingKeys: String, CodingKey { case teamId = "team_id" }
        func encode(to encoder: Encoder) throws {
            try fields.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(teamId, forKey: .teamId)
        }
    }

    /// The bucket's id is chosen HERE, not by the server: the lot builder applies a
    /// list of changes that can fail halfway, and a retry must be able to tell a
    /// bucket that already landed from one that did not (LotBuilderDraft).
    private struct LotRangeInsert: Encodable {
        let id: UUID
        let lotId: UUID
        let templateId: UUID?
        let sortOrder: Int
        let fields: BuyRangeFields
        enum CodingKeys: String, CodingKey {
            case id, lotId = "lot_id", templateId = "template_id", sortOrder = "sort_order"
        }
        func encode(to encoder: Encoder) throws {
            try fields.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(lotId, forKey: .lotId)
            try c.encode(templateId, forKey: .templateId)
            try c.encode(sortOrder, forKey: .sortOrder)
        }
    }

    /// Internal (not private) so a test can pin the wire shape: the banner typed
    /// at creation used to be dropped here and only saved on the next status change.
    struct LotInsert: Encodable {
        let id: UUID, teamId: UUID, name: String, deadline: Date?, banner: String?
        var basis: ValueBasis = .cl
        enum CodingKeys: String, CodingKey { case id, teamId = "team_id", name, deadline, banner, basis = "value_basis" }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(teamId, forKey: .teamId)
            try c.encode(name, forKey: .name)
            try c.encode(deadline, forKey: .deadline)
            try c.encode(banner, forKey: .banner)
            try c.encode(basis, forKey: .basis)
        }
    }

    private struct LotUpdate: Encodable {
        let name: String, deadline: Date?, banner: String?, status: LotStatus
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(deadline, forKey: .deadline)   // explicit null clears it
            try c.encode(banner, forKey: .banner)
            try c.encode(status, forKey: .status)
        }
        enum CodingKeys: String, CodingKey { case name, deadline, banner, status }
    }

    private struct ReportInsert: Encodable {
        let rangeId: UUID, usedCents: Int64, cardCount: Int?
        enum CodingKeys: String, CodingKey { case rangeId = "lot_buy_range_id", usedCents = "used_cents", cardCount = "card_count" }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(rangeId, forKey: .rangeId)
            try c.encode(usedCents, forKey: .usedCents)
            try c.encode(cardCount, forKey: .cardCount)
        }
    }
}

/// Keeps one local GROUP per team lot, on every teammate's phone — the whole of
/// "a lot is a shared group" on the device side (plan §1).
///
/// The rules, each chosen so no card is ever lost:
///   • a visible lot with no group gets one, named after the lot;
///   • a renamed lot renames its group;
///   • a group whose lot is gone (deleted draft, left the team, lot hidden) is
///     DETACHED — `teamLotId` cleared, the cards and the group kept as an ordinary
///     group — unless it is empty, in which case it is removed.
enum LotFolders {
    static func visible(_ lots: [Lot], isLead: Bool) -> [Lot] {
        isLead ? lots : lots.filter { $0.status != .draft }
    }

    /// The Teams tab's lists. NOT `visible`: `sync` builds lot groups from that, and
    /// leaving archived lots out of it would detach their groups — every card in an
    /// archived lot would silently become a plain group's.
    static func listed(_ lots: [Lot], isLead: Bool) -> [Lot] {
        visible(lots, isLead: isLead).filter { !$0.isArchived }
    }

    /// The "Archived · N" section, most recently archived first.
    static func archived(_ lots: [Lot], isLead: Bool) -> [Lot] {
        visible(lots, isLead: isLead).filter(\.isArchived)
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// Can cards be filed into (or seen in) this group right now? A plain group,
    /// always. A lot's group while its lot is open — and, until this launch has
    /// LOADED the lots (no signal at a show), always: hiding it then would strand a
    /// buyer who needs to take a card out of the lot, and send scans to plain
    /// inventory unclaimed. The claim or release it triggers simply queues.
    static func isFileable(_ group: Folder, openLots: Set<UUID>, lotsLoaded: Bool) -> Bool {
        guard let lotId = group.teamLotId else { return true }
        return !lotsLoaded || openLots.contains(lotId)
    }

    /// The local group standing for a lot, if there is one yet.
    static func folder(for lotId: UUID, in context: ModelContext) -> Folder? {
        ((try? context.fetch(FetchDescriptor<Folder>())) ?? []).first { $0.teamLotId == lotId }
    }

    /// Returns the `localId`s of groups that STOPPED being lot groups (detached or
    /// removed), so a caller holding one — the Scan tab's target — can let go of it
    /// rather than keep filing into what is now a plain group.
    @discardableResult
    static func sync(_ lots: [Lot], isLead: Bool, in context: ModelContext) -> Set<UUID> {
        let wanted = visible(lots, isLead: isLead)
        let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        let byLot = Dictionary(folders.compactMap { f in f.teamLotId.map { ($0, f) } },
                               uniquingKeysWith: { first, _ in first })
        var hueIndex = folders.count

        for lot in wanted {
            if let folder = byLot[lot.id] {
                if folder.name != lot.name { folder.name = lot.name }
            } else {
                let folder = Folder(name: lot.name, hueIndex: hueIndex % Caliper.groupHues.count)
                folder.teamLotId = lot.id
                context.insert(folder)
                hueIndex += 1
            }
        }

        let keep = Set(wanted.map(\.id))
        var released: Set<UUID> = []
        for folder in folders {
            guard let lotId = folder.teamLotId, !keep.contains(lotId) else { continue }
            released.insert(folder.localId)
            if folder.cards.isEmpty { context.delete(folder) } else { folder.teamLotId = nil }
        }
        try? context.save()
        return released
    }

    /// What `repair` changed: groups it re-attached, and duplicates it folded into
    /// them (`removed → kept`, so a stored scan target can follow).
    struct RepairReport: Equatable {
        var reattached: Set<UUID> = []
        var merged: [UUID: UUID] = [:]
        var requeued = 0
        var isEmpty: Bool { reattached.isEmpty && merged.isEmpty && requeued == 0 }
    }

    /// Undo the split a lead's cold launch used to cause (fixed 2026-09-28): the
    /// group sync ran against an empty lot list the moment `isLead` flipped, so each
    /// lot group with cards was DETACHED into a plain group of the same name, and a
    /// fresh empty lot group was made beside it. Scans kept filing into the plain
    /// one — no claim, no 3-limit.
    ///
    /// Recognised by what cannot happen any other way: a PLAIN group, named like a
    /// visible lot, holding a card that still says it is in that lot
    /// (`lotClaimLotId`) — every legitimate way out of a lot clears that field
    /// (CardFiling.releaseSlot, a block, a release). Idempotent, so it runs after
    /// every sync and heals any phone that already split, however many times.
    @discardableResult
    static func repair(_ lots: [Lot], isLead: Bool, in context: ModelContext) -> RepairReport {
        var report = RepairReport()
        let folders = (try? context.fetch(FetchDescriptor<Folder>())) ?? []
        for lot in visible(lots, isLead: isLead) {
            let detached = folders.filter { f in
                f.teamLotId == nil && f.name == lot.name
                    && f.cards.contains { $0.lotClaimLotId == lot.id }
            }
            guard let keeper = detached.max(by: { $0.cards.count < $1.cards.count }) else { continue }
            let attached = folders.filter { $0.teamLotId == lot.id }
            keeper.teamLotId = lot.id
            report.reattached.insert(keeper.localId)
            // The duplicate the split made (and any second detached copy): its cards
            // move across as a plain reassignment — NOT through CardFiling, which
            // would release and re-claim slabs the server already holds.
            for dup in attached + detached where dup !== keeper {
                for card in dup.cards { card.folder = keeper }
                report.merged[dup.localId] = keeper.localId
                context.delete(dup)
            }
            // Scans that landed in the plain group after the split were never
            // claimed. Queue them; retryPending claims them one at a time.
            for card in keeper.cards where card.lotClaimLotId == nil {
                card.lotClaimLotId = lot.id
                card.lotClaimState = .pending
                report.requeued += 1
            }
        }
        if !report.isEmpty { try? context.save() }
        return report
    }
}

/// When the lot groups may be re-synced (teams-first plan, phase 0).
///
/// WHY. A lead's cold launch loads the team, THEN its lots. `isLead` flips true
/// the moment members arrive, while `lots` is still the empty launch value — and a
/// sync against that list reads "every lot is gone", detaching every lot group.
/// Reproduced in the Simulator 2026-09-28. So a sync needs proof that `lots` IS
/// this team's list: the team load succeeded and the lot list was stamped for the
/// same team. Not on a team (nil == nil) is a real answer too — that is what lets
/// leaving a team detach its groups.
enum TeamSync {
    static func shouldSyncGroups(teamLoadOK: Bool, teamId: UUID?, lotsLoadedAt: Date?, lotsTeamId: UUID?) -> Bool {
        teamLoadOK && lotsLoadedAt != nil && lotsTeamId == teamId
    }
}
