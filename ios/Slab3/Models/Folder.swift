import Foundation
import SwiftData

/// A destination for cards — a buyer (Pete), a marketplace (Courtyard), a lot.
/// Uniform by design (design.md §5): just a name, its cards, and an export.
/// Archived (shipped) folders stay visible but demoted.
@Model
final class Folder {
    @Attribute(.unique) var localId: UUID
    var serverId: UUID?
    var name: String
    var createdAt: Date
    var archived: Bool

    @Relationship(deleteRule: .nullify, inverse: \Card.folder)
    var cards: [Card] = []

    init(name: String) {
        self.localId = UUID()
        self.name = name
        self.createdAt = Date()
        self.archived = false
    }

    /// Count of cards sharing a given card_key — for the soft sale-limit notice.
    func identicalCount(cardKey: String) -> Int {
        cards.filter { $0.cardKey == cardKey }.count
    }
}
