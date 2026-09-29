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

    enum CodingKeys: String, CodingKey {
        case id, name, deadline, status, banner, createdAt = "created_at"
    }
}

/// A band groups a lot's buckets under one price row (lot dashboard, §8). It has no
/// price span or rules of its own — both come from its buckets — only a category
/// and a place in the list.
struct LotBand: Identifiable, Equatable, Decodable {
    let id: UUID
    let lotId: UUID
    var category: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey { case id, category, lotId = "lot_id", sortOrder = "sort_order" }
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

    enum CodingKeys: String, CodingKey {
        case id, cert, grader, label, player, state
        case lotId = "lot_id", rangeId = "lot_buy_range_id", gradeLabel = "grade_label"
        case priceCents = "price_cents", clConfidence = "cl_confidence", cardSet = "card_set"
        case cardYear = "card_year", cardNumber = "card_number", imageUrl = "image_url"
        case buyerId = "buyer_id", scannedAt = "scanned_at"
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

/// What the team has bought into one bucket: confirmed claims only.
struct RangeUsage: Equatable, Decodable {
    let rangeId: UUID?
    let cards: Int
    let usedCents: Int64
    enum CodingKeys: String, CodingKey { case rangeId = "lot_buy_range_id", cards, usedCents = "used_cents" }
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
    private(set) var bandsByLot: [UUID: [LotBand]] = [:]
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
    func bands(for lot: Lot) -> [LotBand] { bandsByLot[lot.id] ?? [] }
    func claims(for lot: Lot) -> [TeamClaim] { claimsByLot[lot.id] ?? [] }

    /// What this member should see: a buyer never sees a lead's unfinished draft.
    func visibleLots(isLead: Bool) -> [Lot] {
        LotFolders.visible(lots, isLead: isLead)
    }

    // MARK: Load

    func load(teamId: UUID?) async {
        guard TeamsFeature.isAvailable else { return }
        guard let teamId else {
            // Not on a team is a real, loaded answer: the stamp says so, which is
            // what lets a group sync detach the lot groups of a team just left.
            loadedAt = Date(); loadedTeamId = nil
            lots = []; rangesByLot = [:]; library = []; bandsByLot = [:]; usage = [:]
            claimsByLot = [:]; reports = [:]
            return
        }
        let started = Date()
        do {
            let lots: [Lot] = try await Backend.client.from("lots")
                .select("id, name, deadline, status, banner, created_at")
                .eq("team_id", value: teamId).order("created_at", ascending: false)
                .execute().value
            var byLot: [UUID: [BuyRange]] = [:]
            var bands: [UUID: [LotBand]] = [:]
            var usage: [UUID: RangeUsage] = [:]
            var claims: [UUID: [TeamClaim]] = [:]
            var reports: [UUID: RangeReport] = [:]
            if !lots.isEmpty {
                let ids = lots.map(\.id)
                let ranges: [LotRangeRow] = try await Backend.client.from("lot_buy_ranges")
                    .select().in("lot_id", values: ids)
                    .order("sort_order").execute().value
                for row in ranges { byLot[row.lotId, default: []].append(row.range) }
                let bandRows: [LotBand] = try await Backend.client.from("lot_bands")
                    .select().in("lot_id", values: ids).order("sort_order").execute().value
                for band in bandRows { bands[band.lotId, default: []].append(band) }
                let used: [RangeUsage] = try await Backend.client.from("lot_range_usage")
                    .select("lot_buy_range_id, cards, used_cents").in("lot_id", values: ids)
                    .execute().value
                for row in used { if let id = row.rangeId { usage[id] = row } }
                let live: [TeamClaim] = try await Backend.client.from("lot_claims")
                    .select("id, lot_id, lot_buy_range_id, cert, grader, grade_label, price_cents, cl_confidence, label, player, card_set, card_year, card_number, image_url, buyer_id, state, scanned_at")
                    .in("lot_id", values: ids).in("state", values: ["confirmed", "over_limit"])
                    .order("scanned_at", ascending: false).execute().value
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
            if self.rangesByLot != byLot { self.rangesByLot = byLot }
            if self.library != library { self.library = library }
            if self.bandsByLot != bands { self.bandsByLot = bands }
            if self.usage != usage { self.usage = usage }
            if self.claimsByLot != claims { self.claimsByLot = claims }
            if self.reports != reports { self.reports = reports }
        } catch {
            // Keep what we had. A lot view with yesterday's numbers beats a blank one,
            // and nothing about scanning waits on this.
        }
    }

    /// Fill the store without a server — render tests and previews only.
    func seedForPreview(lots: [Lot], ranges: [UUID: [BuyRange]], bands: [UUID: [LotBand]],
                        usage: [UUID: RangeUsage], reports: [UUID: RangeReport] = [:],
                        claims: [UUID: [TeamClaim]] = [:], loadedAt: Date? = nil, teamId: UUID? = nil) {
        self.loadedAt = loadedAt; loadedTeamId = teamId
        self.lots = lots; rangesByLot = ranges; bandsByLot = bands; self.usage = usage
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
        guard TeamsFeature.isAvailable, live == nil else { return }
        let channel = Backend.client.channel("lot-claims-\(teamId.uuidString)")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "lot_claims")
        live = channel
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

    func stopLive() async {
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

    // MARK: Bands (leads)

    func addBand(to lotId: UUID, category: String?, teamId: UUID) async -> String? {
        let order = (bandsByLot[lotId]?.map(\.sortOrder).max() ?? -1) + 1
        return await perform(teamId: teamId) {
            try await Backend.client.from("lot_bands")
                .insert(BandWrite(lotId: lotId, category: category, sortOrder: order)).execute()
        }
    }

    func updateBand(_ band: LotBand, category: String?, teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            try await Backend.client.from("lot_bands")
                .update(["category": category]).eq("id", value: band.id).execute()
        }
    }

    /// Its buckets are kept, standing as bands of their own (band_id → null).
    func deleteBand(_ band: LotBand, teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            try await Backend.client.from("lot_bands").delete().eq("id", value: band.id).execute()
        }
    }

    func moveRange(_ rangeId: UUID, toBand bandId: UUID?, teamId: UUID) async -> String? {
        await perform(teamId: teamId) {
            try await Backend.client.from("lot_buy_ranges")
                .update(["band_id": bandId?.uuidString]).eq("id", value: rangeId).execute()
        }
    }

    /// Drafts only. A lot that has been open holds real buys; closing it is the
    /// way to finish it, and deleting it would cascade those buys away.
    func deleteDraft(_ lot: Lot, teamId: UUID) async -> String? {
        guard lot.status == .draft else { return TeamError.copy(for: "not_draft") }
        return await perform(teamId: teamId) {
            try await Backend.client.from("lots").delete().eq("id", value: lot.id).execute()
        }
    }

    // MARK: A lot's ranges (leads)

    /// Adds a range to a lot as a COPY (so later library edits never move a live
    /// lot's goalposts); `saveToLibrary` also files the same criteria as a template.
    func addRange(_ fields: BuyRangeFields, to lotId: UUID, band bandId: UUID? = nil,
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
                .insert(LotRangeInsert(lotId: lotId, bandId: bandId, templateId: source, sortOrder: order,
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

    private struct LotRangeInsert: Encodable {
        let lotId: UUID
        let bandId: UUID?
        let templateId: UUID?
        let sortOrder: Int
        let fields: BuyRangeFields
        enum CodingKeys: String, CodingKey {
            case lotId = "lot_id", bandId = "band_id", templateId = "template_id", sortOrder = "sort_order"
        }
        func encode(to encoder: Encoder) throws {
            try fields.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(lotId, forKey: .lotId)
            try c.encode(bandId, forKey: .bandId)
            try c.encode(templateId, forKey: .templateId)
            try c.encode(sortOrder, forKey: .sortOrder)
        }
    }

    /// Internal (not private) so a test can pin the wire shape: the banner typed
    /// at creation used to be dropped here and only saved on the next status change.
    struct LotInsert: Encodable {
        let id: UUID, teamId: UUID, name: String, deadline: Date?, banner: String?
        enum CodingKeys: String, CodingKey { case id, teamId = "team_id", name, deadline, banner }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(teamId, forKey: .teamId)
            try c.encode(name, forKey: .name)
            try c.encode(deadline, forKey: .deadline)
            try c.encode(banner, forKey: .banner)
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

    private struct BandWrite: Encodable {
        let lotId: UUID, category: String?, sortOrder: Int
        enum CodingKeys: String, CodingKey { case lotId = "lot_id", category, sortOrder = "sort_order" }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(lotId, forKey: .lotId)
            try c.encode(category, forKey: .category)
            try c.encode(sortOrder, forKey: .sortOrder)
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
