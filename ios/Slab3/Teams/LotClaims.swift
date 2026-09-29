import Foundation
import SwiftData
import Supabase

/// Where a card stands with a team lot (teams phase 4).
enum LotClaimState: String, Codable, Equatable {
    /// Filed into a lot; waiting on Card Ladder, then on the server.
    case checking
    /// In the lot: counts toward the 3-limit and its bucket.
    case confirmed
    /// An offline claim replayed after the lot filled — recorded, counts for
    /// nothing, a lead decides (teams.md §5.1). Stays in the lot group.
    case overLimit = "over_limit"
    /// Fits more than one bucket; the buyer picks. Nothing is held meanwhile.
    case chooseRange = "choose_range"
    /// Not in the lot, and why. The card is back in plain inventory.
    case blocked
    /// Couldn't get an answer yet (no CL price, no connection) — retried on the
    /// next foreground. Never shown as a green light.
    case pending
}

/// The server's answer to one claim, as the card keeps it.
struct LotVerdict: Codable, Equatable {
    struct Existing: Codable, Equatable { let buyer: String?; let scannedAt: Date? }
    struct Candidate: Codable, Equatable, Identifiable {
        let rangeId: UUID; let name: String; let cardsLeft: Int; let centsLeft: Int64
        var id: UUID { rangeId }
    }

    var outcome: String
    var reason: String?
    var failed: String?
    var rangeId: UUID?
    var rangeName: String?
    var copies: Int?
    var warnReasons: [String] = []
    var existing: [Existing] = []
    var candidates: [Candidate] = []
    var priceCents: Int64?
    var grade: String?
    var by: String?
    /// This claim was first attempted with no connection — its replay goes to the
    /// server as an offline one.
    var offline: Bool? = nil
    /// When this answer arrived — lets reconcile tell a stale list from a release.
    var answeredAt: Date? = nil

    var state: LotClaimState {
        switch outcome {
        case "confirmed": .confirmed
        case "over_limit": .overLimit
        case "choose_range": .chooseRange
        case "blocked": .blocked
        default: .pending
        }
    }

    /// Decode `claim_lot_scan`'s jsonb. Kept separate from the stored shape so the
    /// server's key names live in one place.
    static func decode(_ data: Data) throws -> LotVerdict {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return LotVerdict(
            outcome: reply.outcome, reason: reply.reason, failed: reply.failed,
            rangeId: reply.range?.range_id ?? reply.claim?.lot_buy_range_id,
            rangeName: reply.range?.name, copies: reply.copies,
            warnReasons: reply.warn_reasons ?? reply.claim?.warn_reasons ?? [],
            existing: (reply.existing ?? []).map { Existing(buyer: $0.buyer, scannedAt: ISO8601.date($0.scanned_at)) },
            candidates: (reply.candidates ?? []).map {
                Candidate(rangeId: $0.range_id, name: $0.name, cardsLeft: $0.cards_left, centsLeft: $0.cents_left)
            },
            priceCents: reply.price_cents, grade: reply.grade, by: reply.by)
    }

    private struct Reply: Decodable {
        struct RangeRef: Decodable { let range_id: UUID; let name: String }
        struct ClaimRow: Decodable { let lot_buy_range_id: UUID?; let warn_reasons: [String]? }
        struct ExistingRow: Decodable { let buyer: String?; let scanned_at: String? }
        struct CandidateRow: Decodable { let range_id: UUID; let name: String; let cards_left: Int; let cents_left: Int64 }
        let outcome: String
        let reason: String?
        let failed: String?
        let range: RangeRef?
        let claim: ClaimRow?
        let copies: Int?
        let warn_reasons: [String]?
        let existing: [ExistingRow]?
        let candidates: [CandidateRow]?
        let price_cents: Int64?
        let grade: String?
        let by: String?
    }
}

/// What a claim reads as — the toast's fourth line and the row's lot line, in the
/// Caliper label voice. States what happened, without apology.
enum LotVerdictText {
    enum Tone { case quiet, good, warn }

    static func line(state: LotClaimState, verdict: LotVerdict?) -> (text: String, tone: Tone) {
        switch state {
        case .checking: return ("Checking lot…", .quiet)
        case .pending:
            switch verdict?.reason {
            case "cl_not_connected": return ("Lot · connect Card Ladder to claim", .warn)
            // Scanned with no signal: the card is in inventory and in the lot group
            // here, but nothing on the server has seen it — never a green light.
            case "network": return ("Unverified · syncs when online", .warn)
            default: return ("Lot · not checked yet · retrying", .warn)
            }
        case .confirmed:
            var parts = ["In " + (verdict?.rangeName ?? "lot")]
            if let copies = verdict?.copies { parts.append("\(copies) of 3") }
            if verdict?.warnReasons.contains("near_range_edge") == true { parts.append("near edge") }
            return (parts.joined(separator: " · "), .good)
        case .overLimit: return ("Over the limit · a lead decides", .warn)
        case .chooseRange:
            let n = verdict?.candidates.count ?? 0
            return ("Pick a bucket · fits \(n)", .warn)
        case .blocked: return ("Not in lot — " + blockedReason(verdict), .warn)
        }
    }

    static func blockedReason(_ v: LotVerdict?) -> String {
        switch v?.reason {
        case "limit_reached": return "3 already bought"
        case "duplicate_cert": return (v?.by).map { "\($0) already has this slab" } ?? "this slab is already in"
        case "range_full_count": return "bucket is full"
        case "range_full_budget": return "bucket budget is spent"
        case "no_cl_value": return "no Card Ladder value"
        case "lot_closed": return "lot is closed"
        case "not_member": return "not on this team"
        case "released": return "released by a lead"
        case "no_matching_range":
            switch v?.failed {
            case "value": return v?.priceCents.map { "no bucket at \(Money.dollars($0))" } ?? "no bucket at this value"
            case "grade": return v?.grade.map { "grade \($0) fits no bucket" } ?? "grade fits no bucket"
            case "grade_unknown": return "grade unknown"
            case "confidence": return "CL confidence too low"
            case "year": return "year fits no bucket"
            default: return "fits no bucket"
            }
        default: return "not accepted"
        }
    }
}

extension Card {
    var lotClaimState: LotClaimState? {
        get { lotClaimStateRaw.flatMap(LotClaimState.init(rawValue:)) }
        set { lotClaimStateRaw = newValue?.rawValue }
    }

    var lotVerdict: LotVerdict? {
        get { lotVerdictData.flatMap { try? JSONDecoder().decode(LotVerdict.self, from: $0) } }
        set { lotVerdictData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    /// Holds a slot on the server that must be given back if the card leaves.
    var holdsLotSlot: Bool { lotClaimState == .confirmed || lotClaimState == .overLimit }
}

/// Claims and releases (teams phase 4). Called ONLY through `CardFiling` and
/// `CardDeletion`, so no path into or out of a lot can skip them.
@MainActor
enum LotClaims {
    /// Posted after any claim or release, so the lot dashboard's totals reload.
    static let changed = Notification.Name("LotClaims.changed")

    /// Claim `card` into `lotId`. Waits for the card's own price refresh (the scan
    /// path starts one), because the server buckets on the CL Value that refresh
    /// caches — asking first would only come back "pending".
    static func claim(_ card: Card, lotId: UUID, rangeId: UUID? = nil, in context: ModelContext) async {
        guard TeamsFeature.isAvailable else { return }

        // A claim that could not reach the server before is an OFFLINE replay: the
        // server then records a buy that arrives after its card's slots (or its
        // bucket) filled as over-limit, for a lead to decide, rather than turning
        // away a slab the buyer already paid for (teams.md §5.1).
        let offline = card.lotVerdict?.reason == "network" || card.lotVerdict?.offline == true
        // Filed straight back after being taken out: the release never needs to
        // reach the server (it still holds the claim, and returns it to this buyer).
        PendingReleaseStore.shared.cancel(lotId: lotId, cert: card.certNumber, grader: card.grader.rawValue)
        card.lotClaimLotId = lotId
        card.lotClaimState = .checking
        try? context.save()

        await waitForPrices(card)
        var verdict = await request(card, lotId: lotId, rangeId: rangeId, offline: offline)
        // Cold server cache (a card filed long after it was priced, or scanned with
        // no signal): one cache-first refresh warms it, then ask once more.
        if verdict.outcome == "pending", verdict.reason == "pending_price", !card.pricesLoading {
            await spaceColdRefresh()
            await PriceService.refresh(card, in: context)
            verdict = await request(card, lotId: lotId, rangeId: rangeId, offline: offline)
        }
        verdict.offline = offline || verdict.reason == "network"
        apply(verdict, to: card, lotId: lotId, in: context)
    }

    /// Give a slot back — the card was un-filed, moved to another group, or is
    /// being deleted. Recorded durably FIRST, then sent through the serial queue;
    /// whatever does not land is retried with `retryPending` (PendingReleaseStore).
    static func queueRelease(lotId: UUID, cert: String, grader: Grader) {
        let release = PendingRelease(lotId: lotId, cert: cert, grader: grader.rawValue)
        PendingReleaseStore.shared.add(release)
        LotClaimQueue.shared.enqueue(.release(release))
    }

    /// One release request. Only the queue calls this.
    static func release(_ release: PendingRelease) async -> ReleaseOutcome {
        guard TeamsFeature.isAvailable else { return .retry }
        struct Reply: Decodable { let outcome: String }
        let result: ReleaseOutcome
        do {
            let data = try await Backend.client.rpc("release_lot_claim", params: [
                "p_lot_id": release.lotId.uuidString, "p_cert": release.cert, "p_grader": release.grader,
            ]).execute().data
            result = .classify(outcome: (try? JSONDecoder().decode(Reply.self, from: data))?.outcome, errorCode: nil)
        } catch let error as PostgrestError {
            result = .classify(outcome: nil, errorCode: error.message)
        } catch {
            result = .classify(outcome: nil, errorCode: nil)
        }
        if result == .done { NotificationCenter.default.post(name: changed, object: nil) }
        return result
    }

    /// Cold-cache refreshes (a claim that found no CL price on the server) are
    /// spaced a second apart — Card Ladder's ≤1 request/second rule. The queue
    /// already runs claims one at a time; this keeps a run of them from bunching.
    private static var lastColdRefresh: Date?
    private static func spaceColdRefresh() async {
        if let last = lastColdRefresh {
            let wait = 1.0 - Date().timeIntervalSince(last)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        lastColdRefresh = Date()
    }

    /// How a batch of offline scans landed — the reconnect summary (teams.md §10).
    struct SyncSummary: Equatable {
        var synced = 0, inLot = 0, overLimit = 0, notInLot = 0, pickBucket = 0, stillWaiting = 0

        var line: String {
            var parts = ["Synced \(synced) offline \(synced == 1 ? "scan" : "scans")"]
            if inLot > 0 { parts.append("\(inLot) in lot") }
            if overLimit > 0 { parts.append("\(overLimit) over limit") }
            if notInLot > 0 { parts.append("\(notInLot) not in lot") }
            if pickBucket > 0 { parts.append("\(pickBucket) to place") }
            if stillWaiting > 0 { parts.append("\(stillWaiting) still waiting") }
            return parts.joined(separator: " · ")
        }
    }

    /// Everything still waiting for an answer, oldest scan first (teams.md §10) —
    /// called when the app comes forward and when the connection returns. Returns
    /// a summary only when offline scans were among them, so a routine retry of a
    /// cold-cache card never pops a bar.
    @discardableResult
    static func retryPending(in context: ModelContext) async -> SyncSummary? {
        guard TeamsFeature.isAvailable else { return nil }
        // Releases first: a slot given back offline must be free on the server
        // before this phone's own waiting claims compete for it.
        for release in PendingReleaseStore.shared.all {
            await LotClaimQueue.shared.submit(.release(release), in: context)
        }
        let all = (try? context.fetch(FetchDescriptor<Card>())) ?? []
        let waiting = all
            .filter { $0.lotClaimState == .pending || $0.lotClaimState == .checking }
            .filter { card in card.lotClaimLotId.map { card.folder?.teamLotId == $0 } ?? false }
            .sorted { $0.scannedAt < $1.scannedAt }
        var summary = SyncSummary()
        for card in waiting {
            guard let lotId = card.lotClaimLotId else { continue }
            let wasOffline = card.lotVerdict?.reason == "network" || card.lotVerdict?.offline == true
            await LotClaimQueue.shared.submit(.claim(cardId: card.localId, lotId: lotId, rangeId: nil), in: context)
            guard wasOffline else { continue }
            summary.synced += 1
            switch card.lotClaimState {
            case .confirmed: summary.inLot += 1
            case .overLimit: summary.overLimit += 1
            case .blocked: summary.notInLot += 1
            case .chooseRange: summary.pickBucket += 1
            default: summary.stillWaiting += 1; summary.synced -= 1
            }
        }
        return summary.synced > 0 ? summary : nil
    }

    // MARK: Internals

    private static func waitForPrices(_ card: Card) async {
        for _ in 0..<120 where card.pricesLoading {   // ≤30s; a refresh times out well before
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private struct ClaimParams: Encodable {
        let p_lot_id: UUID, p_cert: String, p_grader: String, p_scanned_at: String
        let p_range_id: UUID?, p_offline: Bool
    }

    private static func request(_ card: Card, lotId: UUID, rangeId: UUID?, offline: Bool) async -> LotVerdict {
        do {
            let params = ClaimParams(p_lot_id: lotId, p_cert: card.certNumber, p_grader: card.grader.rawValue,
                                     p_scanned_at: ISO8601.string(card.scannedAt),
                                     p_range_id: rangeId, p_offline: offline)
            let data = try await Backend.client.rpc("claim_lot_scan", params: params).execute().data
            return try LotVerdict.decode(data)
        } catch let error as PostgrestError {
            switch error.message {
            // Membership and a closed lot are answers; a missing CL connection is
            // something the buyer can fix, so it waits rather than blocks.
            case "not_member": return LotVerdict(outcome: "blocked", reason: "not_member")
            case "cl_not_connected": return LotVerdict(outcome: "pending", reason: "cl_not_connected")
            default: return LotVerdict(outcome: "pending", reason: "error")
            }
        } catch {
            return LotVerdict(outcome: "pending", reason: "network")
        }
    }

    /// The server is the truth for what is in a lot. A slab this phone thinks it
    /// holds, but which the server no longer lists (a lead released it), goes back
    /// to plain inventory and says so. Only for answers older than the list — a
    /// claim confirmed while the list was loading is not missing, just newer.
    static func reconcile(_ claimsByLot: [UUID: [TeamClaim]], lots: [Lot], loadedAt: Date?,
                          myUserId: UUID?, in context: ModelContext) {
        // No feature gate here: this touches only the local store, and it runs only
        // after a lot load — which is itself gated — has produced a list to check.
        guard let loadedAt, let myUserId else { return }
        let known = Set(lots.map(\.id))
        let all = (try? context.fetch(FetchDescriptor<Card>())) ?? []
        var changed = false
        for card in all where card.holdsLotSlot {
            guard let lotId = card.lotClaimLotId, known.contains(lotId),
                  let answered = card.lotVerdict?.answeredAt, answered < loadedAt else { continue }
            let held = (claimsByLot[lotId] ?? []).contains {
                $0.cert == card.certNumber && $0.grader == card.grader.rawValue && $0.buyerId == myUserId
            }
            guard !held else { continue }
            card.lotClaimState = .blocked
            card.lotVerdict = LotVerdict(outcome: "blocked", reason: "released", answeredAt: Date())
            if card.folder?.teamLotId == lotId { card.folder = nil }
            changed = true
        }
        if changed { try? context.save() }
    }

    private static func apply(_ verdict: LotVerdict, to card: Card, lotId: UUID, in context: ModelContext) {
        var verdict = verdict
        verdict.answeredAt = Date()
        card.lotClaimLotId = lotId
        card.lotClaimState = verdict.state
        card.lotVerdict = verdict
        // Blocked: back to plain inventory (plan §6) — the lot group holds only
        // real claims. No release: nothing was claimed.
        if verdict.state == .blocked, card.folder?.teamLotId == lotId {
            card.folder = nil
        }
        try? context.save()
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
