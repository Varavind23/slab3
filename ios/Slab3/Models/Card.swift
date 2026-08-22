import Foundation
import SwiftData

/// Where a card's detail lookup stands. Scanning always succeeds locally; the
/// name/set/grade fill in when the cert lookup resolves (or the user confirms).
enum LookupStatus: String, Codable {
    case pending // scanned, not yet looked up
    case resolved // card data present
    case needsConfirm // lookup unavailable (e.g. CGC) — user confirms from slab
    case notFound // valid format, no data at the grader
}

/// A scanned graded card. Mirrors the `cards` table (supabase/migrations):
/// grader, cert_number, card_key, name, set, year, grade, scanned_at,
/// manual_price_cents, notes. `serverId` links to the row once synced.
@Model
final class Card {
    @Attribute(.unique) var localId: UUID
    var serverId: UUID?

    var graderRaw: String
    var certNumber: String
    var cardKey: String

    var name: String?
    var set: String?
    var year: Int?
    var grade: String?

    var scannedAt: Date
    var lookupStatusRaw: String
    var manualPriceCents: Int?
    var notes: String?

    var grader: Grader { Grader(rawValue: graderRaw) ?? .psa }
    var lookupStatus: LookupStatus {
        get { LookupStatus(rawValue: lookupStatusRaw) ?? .pending }
        set { lookupStatusRaw = newValue.rawValue }
    }

    /// Display title: real card data when resolved, else the cert reference.
    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return "\(grader.rawValue.uppercased()) #\(certNumber)"
    }
    var displaySubtitle: String {
        [set, grade.map { "Grade \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    init(scan: CertScan) {
        self.localId = UUID()
        self.graderRaw = scan.grader.rawValue
        self.certNumber = scan.certNumber
        // card_key is provisional until lookup fills set/grade; recomputed then.
        self.cardKey = CardKey.make(grader: scan.grader, set: nil, cardId: scan.certNumber, grade: nil)
        self.scannedAt = Date()
        self.lookupStatusRaw = LookupStatus.pending.rawValue
    }

    /// Recompute card_key once real card data is known (post-lookup/confirm).
    func refreshCardKey() {
        cardKey = CardKey.make(grader: grader, set: set, cardId: name ?? certNumber, grade: grade)
    }
}
