import Foundation
import SwiftData
import SwiftUI

/// A destination for cards — a buyer (pete), a marketplace, a lot.
///
/// **Caliper calls this a group**, and every user-facing string in the app says
/// "group". The SwiftData entity keeps the name `Folder` deliberately: renaming a
/// @Model entity is a store migration, and getting it wrong drops every existing
/// card→group assignment on a device that already has inventory. The vocabulary
/// change is free; the entity rename is not, so it waits for a real migration
/// (README.md, "Folder → Group").
///
/// Group names are rendered verbatim, never capitalised or reformatted — `philcgc`
/// and `Triumph 7/24` are what the user typed and how they'll look for them.
@Model
final class Folder {
    @Attribute(.unique) var localId: UUID
    var serverId: UUID?
    var name: String
    var createdAt: Date
    var archived: Bool

    /// Index into `Caliper.groupHues`. The hue is a buyer identifier and always
    /// travels with the name — never on its own, never as a background.
    var hueIndex: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \Card.folder)
    var cards: [Card] = []

    init(name: String, hueIndex: Int = 0) {
        self.localId = UUID()
        self.name = name
        self.createdAt = Date()
        self.archived = false
        self.hueIndex = hueIndex
    }

    var hue: Color { Caliper.groupHues[hueIndex % Caliper.groupHues.count] }

    /// Count of cards sharing a given card_key — for the soft sale-limit notice.
    func identicalCount(cardKey: String) -> Int {
        cards.filter { $0.cardKey == cardKey }.count
    }
}
