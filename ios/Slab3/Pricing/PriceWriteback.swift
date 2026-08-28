import Foundation

/// The single rule that fixes "prices come up blank on refresh", isolated from
/// the network so it can be tested directly: how one source's answer updates the
/// price we already hold.
///
/// The bug was that every non-success wrote `nil`. Here, only an AUTHORITATIVE
/// answer clears a number:
///   • `.price`        → new value, status ok
///   • `.notListed`    → the source says it has nothing → clear (authoritative)
///   • `.notConnected` → Card Ladder only; clearing is the ToS gate, not an error
///   • `.unreachable`  → offline / rate limited / source error → KEEP the value,
///                       mark it unconfirmed so the UI can show it as of its date
enum PriceWriteback {
    struct Stored: Equatable {
        var cents: Int?
        var asOf: Date?
        var status: PriceStatus

        static let none = Stored(cents: nil, asOf: nil, status: .unknown)
    }

    enum Answer: Equatable {
        case price(Int)
        case notListed
        case unreachable
        case notConnected
    }

    static func apply(_ answer: Answer, to stored: Stored, now: Date = Date()) -> Stored {
        switch answer {
        case .price(let cents):
            return Stored(cents: cents, asOf: now, status: .ok)
        case .notListed:
            return Stored(cents: nil, asOf: nil, status: .notListed)
        case .notConnected:
            return Stored(cents: nil, asOf: nil, status: .notConnected)
        case .unreachable:
            // Keep cents AND its original asOf — the date belongs to the number,
            // not to the attempt that failed to refresh it.
            return Stored(cents: stored.cents, asOf: stored.asOf, status: .unavailable)
        }
    }
}
