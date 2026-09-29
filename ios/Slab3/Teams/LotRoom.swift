import Foundation

/// What a buyer can still buy — the first thing the Teams tab says (teams-first
/// plan, D15: "what I can still buy" leads, the bar sits behind it).
///
/// A bucket has TWO caps, cards and dollars (CL Value at claim), and it is full
/// the moment either runs out — the same rule `claim_lot_scan` enforces
/// (`range_full_count` / `range_full_budget`). So room is the pair, and a full
/// bucket shows no room on either side even if the other cap has slack: offering
/// "$12k left" in a bucket that takes no more cards would be a promise the server
/// refuses. The bar follows the TIGHTER cap for the same reason.
///
/// Counts only CONFIRMED claims (the server's `lot_range_usage` view): an
/// over-limit buy holds no slot. Integer cents throughout, never a float of money.
enum LotRoom {
    struct Room: Equatable {
        var cardsUsed: Int
        var centsUsed: Int64
        var maxCards: Int
        var budgetCents: Int64
        /// Room on each side; both 0 once either cap is reached.
        var cardsLeft: Int
        var centsLeft: Int64

        var isFull: Bool { cardsLeft == 0 || centsLeft == 0 }
        /// The tighter cap's share used, 0…1.
        var fraction: Double {
            let byCards = maxCards > 0 ? Double(cardsUsed) / Double(maxCards) : 0
            let byCents = budgetCents > 0 ? Double(centsUsed) / Double(budgetCents) : 0
            return min(1, max(0, max(byCards, byCents)))
        }
        /// Amber from here (Caliper's "look at this", never red).
        var isNear: Bool { fraction >= 0.9 }
        var percentUsed: Int { Int(fraction * 100) }

        /// "169 cards · $27.8k left", or "Full".
        var leftLine: String {
            guard !isFull else { return "Full" }
            return "\(cardsLeft) \(cardsLeft == 1 ? "card" : "cards") · \(Money.compact(centsLeft)) left"
        }
    }

    static func bucket(_ range: BuyRange, usage: RangeUsage?) -> Room {
        let cards = usage?.cards ?? 0, cents = usage?.usedCents ?? 0
        var cardsLeft = max(0, range.maxCards - cards)
        var centsLeft = max(0, range.budgetCents - cents)
        if cardsLeft == 0 || centsLeft == 0 { cardsLeft = 0; centsLeft = 0 }
        return Room(cardsUsed: cards, centsUsed: cents, maxCards: range.maxCards,
                    budgetCents: range.budgetCents, cardsLeft: cardsLeft, centsLeft: centsLeft)
    }

    /// A band, or a whole lot: the sum of its buckets' rooms — so a full bucket
    /// adds nothing to "left", exactly as it takes nothing on the server.
    static func sum(_ rooms: [Room]) -> Room {
        rooms.reduce(Room(cardsUsed: 0, centsUsed: 0, maxCards: 0, budgetCents: 0, cardsLeft: 0, centsLeft: 0)) {
            Room(cardsUsed: $0.cardsUsed + $1.cardsUsed, centsUsed: $0.centsUsed + $1.centsUsed,
                 maxCards: $0.maxCards + $1.maxCards, budgetCents: $0.budgetCents + $1.budgetCents,
                 cardsLeft: $0.cardsLeft + $1.cardsLeft, centsLeft: $0.centsLeft + $1.centsLeft)
        }
    }

    static func lot(ranges: [BuyRange], usage: [UUID: RangeUsage]) -> Room {
        sum(ranges.map { bucket($0, usage: usage[$0.id]) })
    }
}

extension Money {
    /// Room-sized money: "$950", "$27.8k", "$1.2M". Truncated, never rounded up —
    /// a "left" figure must not promise a cent more than there is.
    static func compact(_ cents: Int64) -> String {
        let dollars = max(0, cents) / 100
        func trimmed(_ whole: Int64, _ tenth: Int64, _ unit: String) -> String {
            tenth == 0 ? "$\(whole)\(unit)" : "$\(whole).\(tenth)\(unit)"
        }
        switch dollars {
        case ..<1_000: return "$\(dollars)"
        case ..<1_000_000: return trimmed(dollars / 1_000, dollars % 1_000 / 100, "k")
        default: return trimmed(dollars / 1_000_000, dollars % 1_000_000 / 100_000, "M")
        }
    }
}
