import Foundation

/// The one-screen lot builder's state and its save, as pure values (teams-first
/// plan, D6: name, deadline, banner, buckets from the library or new — one screen).
///
/// WHY PURE. A save is several writes (the lot, then each bucket, then its status)
/// and any of them can fail at a show with bad signal. So the builder does not
/// write as it goes: it holds a draft, and `operations(against:)` computes exactly
/// what differs from what the server has. Every bucket carries its OWN id from the
/// moment it is added, so after a half-failed save and a reload, the next attempt
/// computes only what is still missing — never a second copy of a bucket.
struct LotBuilderDraft: Equatable {
    struct Bucket: Identifiable, Equatable {
        /// Becomes the lot_buy_ranges id — chosen here, see above.
        var id = UUID()
        var fields: BuyRangeFields
        /// Where it was copied from in the library, if anywhere.
        var templateId: UUID?
    }

    enum Op: Equatable {
        case createLot(id: UUID, name: String, deadline: Date?, banner: String?)
        case updateLot(id: UUID, name: String, deadline: Date?, banner: String?, status: LotStatus)
        case addRange(id: UUID, lotId: UUID, templateId: UUID?, sortOrder: Int, fields: BuyRangeFields)
        case updateRange(id: UUID, sortOrder: Int, fields: BuyRangeFields)
        case deleteRange(id: UUID)
    }

    /// The lot's id — fixed for a new lot too, so a retried create is the same lot.
    var lotId: UUID
    var name = ""
    var hasDeadline = true
    var deadline: Date
    var banner = ""
    var buckets: [Bucket] = []

    /// A new lot.
    init(now: Date = Date()) {
        lotId = UUID()
        deadline = LotText.defaultDeadline(from: now)
    }

    /// An existing lot, as it stands on the server.
    init(lot: Lot, ranges: [BuyRange], now: Date = Date()) {
        lotId = lot.id
        name = lot.name
        hasDeadline = lot.deadline != nil
        deadline = lot.deadline ?? LotText.defaultDeadline(from: now)
        banner = lot.banner ?? ""
        buckets = ranges.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
            .map { Bucket(id: $0.id, fields: $0.fields, templateId: $0.templateId) }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBanner: String? {
        let b = banner.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }

    /// Add a copy of a library range. The lot's copy is its own — later library
    /// edits never move a live lot's goalposts.
    mutating func add(template: BuyRange) {
        buckets.append(Bucket(fields: template.fields, templateId: template.id))
    }

    /// What stops a save, in the builder's own words; nil when it can go.
    /// `held` are buckets that already hold slabs: on an open lot they cannot be
    /// taken out, because the claims in them would lose their bucket.
    func problem(opening: Bool, existing: [BuyRange], held: Set<UUID>) -> String? {
        if trimmedName.isEmpty { return "Name the lot." }
        if opening && buckets.isEmpty { return "Add at least one bucket before opening the lot." }
        let kept = Set(buckets.map(\.id))
        if existing.contains(where: { !kept.contains($0.id) && held.contains($0.id) }) {
            return "A bucket you removed already has cards in it. Put it back, or release those cards first."
        }
        return nil
    }

    /// Everything that must change on the server to make it match this draft, in a
    /// safe order: the lot exists before its buckets; buckets are settled before the
    /// lot opens (so buyers never see a half-built lot).
    func operations(existingLot: Lot?, existingRanges: [BuyRange], status: LotStatus) -> [Op] {
        var ops: [Op] = []
        let deadlineValue = hasDeadline ? deadline : nil
        if existingLot == nil {
            ops.append(.createLot(id: lotId, name: trimmedName, deadline: deadlineValue, banner: trimmedBanner))
        }
        let kept = Set(buckets.map(\.id))
        for range in existingRanges where !kept.contains(range.id) {
            ops.append(.deleteRange(id: range.id))
        }
        let byId = Dictionary(existingRanges.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (order, bucket) in buckets.enumerated() {
            if let old = byId[bucket.id] {
                if old.fields != bucket.fields || old.sortOrder != order {
                    ops.append(.updateRange(id: bucket.id, sortOrder: order, fields: bucket.fields))
                }
            } else {
                ops.append(.addRange(id: bucket.id, lotId: lotId, templateId: bucket.templateId,
                                     sortOrder: order, fields: bucket.fields))
            }
        }
        let lotChanged = existingLot.map {
            $0.name != trimmedName || $0.deadline != deadlineValue || $0.banner != trimmedBanner || $0.status != status
        } ?? (status != .draft)
        if lotChanged {
            ops.append(.updateLot(id: lotId, name: trimmedName, deadline: deadlineValue,
                                  banner: trimmedBanner, status: status))
        }
        return ops
    }

    /// Unsaved changes, for the "discard?" question on the way out.
    func differs(from lot: Lot?, ranges: [BuyRange]) -> Bool {
        guard let lot else { return !trimmedName.isEmpty || !buckets.isEmpty || trimmedBanner != nil }
        return !operations(existingLot: lot, existingRanges: ranges, status: lot.status).isEmpty
    }
}
