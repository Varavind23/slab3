import Foundation
import SwiftData

/// A slab this phone has given back to a lot, until the server has heard it.
///
/// WHY IT IS STORED (teams-first plan, phase 0). A release used to be one
/// fire-and-forget request, and the card forgot its lot state at once — so an
/// un-file or delete with no signal (a card show, most of the time) left the
/// server holding the claim forever: one of the 3 copies and part of a bucket's
/// budget, gone for the whole team, with nothing left on the phone to retry it.
/// It is written BEFORE the request, so even an app kill mid-request cannot lose it.
///
/// Values, not a card: the card may be deleted by the time the server answers.
struct PendingRelease: Codable, Hashable {
    let lotId: UUID
    let cert: String
    let grader: String
    /// The account that gave the slab back. Sent only while that account is signed
    /// in — another account would be refused (`not_member`/`not_lead`), and that
    /// refusal counts as done, silently dropping it. Nil on releases queued before
    /// this field existed: sent as before.
    var userId: UUID? = nil
    var queuedAt: Date = Date()

    func belongs(to user: UUID?) -> Bool { userId == nil || userId == user }

    /// One slab in one lot — what dedupes and what a re-claim cancels.
    var key: String { "\(lotId.uuidString)|\(grader)|\(cert)" }
}

/// The durable half: a small JSON list in UserDefaults. Not a SwiftData model —
/// it holds a handful of value tuples with no relationship to a card, and a new
/// `@Model` would widen the container every user's store opens with.
final class PendingReleaseStore {
    static let shared = PendingReleaseStore()
    static let key = "teams_pending_releases"

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var all: [PendingRelease] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([PendingRelease].self, from: data)) ?? []
    }

    func contains(_ release: PendingRelease) -> Bool { all.contains { $0.key == release.key } }

    func add(_ release: PendingRelease) {
        var list = all
        guard !list.contains(where: { $0.key == release.key }) else { return }
        list.append(release)
        save(list)
    }

    func remove(_ release: PendingRelease) { save(all.filter { $0.key != release.key }) }

    /// The slab is being claimed back into the same lot: the server still holds
    /// the old claim, and a claim by the same buyer returns it unchanged.
    func cancel(lotId: UUID, cert: String, grader: String) {
        remove(PendingRelease(lotId: lotId, cert: cert, grader: grader))
    }

    private func save(_ list: [PendingRelease]) {
        if list.isEmpty { defaults.removeObject(forKey: Self.key); return }
        defaults.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }
}

/// How a release request ended: `done` drops it from the store, `retry` keeps it.
enum ReleaseOutcome: Equatable {
    case done, retry

    /// `outcome` is the RPC's answer, `errorCode` a raised exception's message,
    /// nil for both a network failure. Answers that mean "nothing left to release
    /// from this phone" are done — including refusals, which no retry would change.
    static func classify(outcome: String?, errorCode: String?) -> ReleaseOutcome {
        if let outcome { return ["released", "not_claimed"].contains(outcome) ? .done : .retry }
        switch errorCode {
        case "not_member", "not_lead": return .done
        default: return .retry        // no connection, signed out, a server hiccup
        }
    }
}

/// Every claim and release, ONE AT A TIME, in the order they were asked for.
///
/// WHY SERIAL (teams-first plan, phase 0). Filing 20 older cards into a lot used to
/// start 20 claims at once, each free to refresh its card's prices — a burst at
/// Card Ladder, which allows ≤1 request a second and 200 a day per user, and at
/// Courtyard, which 403s an IP that hammers it (the same reason CLAUDE.md removed
/// bulk refresh). One worker also gives releases and claims of the same slab a
/// defined order: un-file then re-file always reaches the server in that order.
@MainActor
final class LotClaimQueue {
    static let shared = LotClaimQueue()

    enum Op: Equatable {
        case claim(cardId: UUID, lotId: UUID, rangeId: UUID?)
        case release(PendingRelease)

        /// Two queued ops with one key are one job: the later one wins.
        var key: String {
            switch self {
            case .claim(let cardId, _, _): "claim|\(cardId.uuidString)"
            case .release(let r): "release|\(r.key)"
            }
        }
    }

    private struct Item {
        var op: Op
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private var items: [Item] = []
    private var worker: Task<Void, Never>?
    /// The context claims run in — the app has one main context; the latest one
    /// handed in is used.
    private var context: ModelContext?
    /// What an op does. Replaced in tests.
    var perform: (Op, ModelContext?) async -> Void = LotClaimQueue.run

    /// Ops waiting to run (not counting one in flight). Tests read it.
    var pending: [Op] { items.map(\.op) }
    var isIdle: Bool { items.isEmpty && worker == nil }

    func enqueue(_ op: Op, in context: ModelContext? = nil) {
        insert(op, waiter: nil, context: context)
    }

    /// Enqueue and wait until that op has run — for callers that need its result
    /// on the card (the reconnect summary).
    func submit(_ op: Op, in context: ModelContext? = nil) async {
        await withCheckedContinuation { continuation in
            insert(op, waiter: continuation, context: context)
        }
    }

    /// Sign-out: nothing queued may run as the next account. Waiting releases stay
    /// in `PendingReleaseStore`, stamped with their owner; waiters are let go.
    func reset() {
        let dropped = items
        items = []
        dropped.forEach { $0.waiters.forEach { $0.resume() } }
    }

    /// Wait for everything queued so far. Tests only.
    func drain() async {
        while let current = worker { await current.value }
    }

    private func insert(_ op: Op, waiter: CheckedContinuation<Void, Never>?, context: ModelContext?) {
        if let context { self.context = context }
        if let i = items.firstIndex(where: { $0.op.key == op.key }) {
            items[i].op = op
            if let waiter { items[i].waiters.append(waiter) }
        } else {
            items.append(Item(op: op, waiters: waiter.map { [$0] } ?? []))
        }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !self.items.isEmpty {
                let item = self.items.removeFirst()
                await self.perform(item.op, self.context)
                item.waiters.forEach { $0.resume() }
            }
            self?.worker = nil
        }
    }

    /// The real work of one op.
    private static func run(_ op: Op, _ context: ModelContext?) async {
        switch op {
        case .release(let release):
            // Cancelled while it waited (the slab was claimed back): nothing to do.
            guard PendingReleaseStore.shared.contains(release) else { return }
            // Another account's, queued before a sign-out: kept for when it is back.
            guard release.belongs(to: LotClaims.currentUserId) else { return }
            if await LotClaims.release(release) == .done { PendingReleaseStore.shared.remove(release) }
        case .claim(let cardId, let lotId, let rangeId):
            guard let context else { return }
            let find = FetchDescriptor<Card>(predicate: #Predicate { $0.localId == cardId })
            // Deleted while it waited: there is nothing left to claim.
            guard let card = try? context.fetch(find).first else { return }
            await LotClaims.claim(card, lotId: lotId, rangeId: rangeId, in: context)
        }
    }
}
