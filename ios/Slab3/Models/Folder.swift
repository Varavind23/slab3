import Foundation
import SwiftData
import SwiftUI

/// A destination for cards — a buyer, a marketplace, a lot.
///
/// **Caliper calls this a group**, and every user-facing string in the app says
/// "group". The SwiftData entity keeps the name `Folder` deliberately: renaming a
/// @Model entity is a store migration, and getting it wrong drops every existing
/// card→group assignment on a device that already has inventory. The vocabulary
/// change is free; the entity rename is not, so it waits for a real migration
/// (README.md, "Folder → Group").
///
/// Group names are rendered verbatim, never capitalised or reformatted — `bulk cgc`
/// and `Show 7/24` are what the user typed and how they'll look for them.
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

    /// When a card was last filed into this group.
    ///
    /// It drives the Cards swipe action, which offers "file into the group you last
    /// used". Recency lives on the MODEL rather than as a stored group id in
    /// preferences because a deleted group takes its recency with it — there is no
    /// dangling reference to re-validate on every read, and "the most recent one
    /// still standing" falls out for free.
    ///
    /// Optional on purpose: this project has no VersionedSchema/SchemaMigrationPlan
    /// (Slab3App uses a bare `.modelContainer(for:)`), so additive-optional is what
    /// lets SwiftData lightweight-migrate the inventories already on users' phones.
    var lastUsedAt: Date?

    /// Set when this group IS a team lot (plan §1: a lot is a shared group, not a
    /// second concept beside groups). The server's `lots.id`. `LotFolders.sync`
    /// creates and names these from the team's lots, so every teammate's phone
    /// carries the same group; nil for every ordinary group.
    ///
    /// Additive-optional for the same reason as `lastUsedAt` — no migration plan.
    var teamLotId: UUID?

    var isTeamLot: Bool { teamLotId != nil }

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

    /// Record that a card was just filed here. The rule that keeps this honest:
    /// anywhere that sets `card.folder = group`, call this beside it, or the swipe
    /// action starts offering a group the user has not touched in weeks.
    func markUsed(at time: Date = Date()) {
        lastUsedAt = time
    }

    /// The group the Cards swipe offers to file into: the one most recently filed
    /// into. `nil` when no card has ever been filed — the swipe then opens the
    /// group picker instead of guessing, which is the same rule prices follow.
    static func mostRecentlyUsed(in groups: [Folder]) -> Folder? {
        groups
            .filter { !$0.archived && !$0.isTeamLot }
            .compactMap { group in group.lastUsedAt.map { (group: group, used: $0) } }
            .max { $0.used < $1.used }?
            .group
    }
}
