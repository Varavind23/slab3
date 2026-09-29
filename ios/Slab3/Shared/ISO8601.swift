import Foundation

/// Parses the ISO 8601 timestamps our Edge Functions send.
///
/// Exists because `JSONDecoder()`'s default date strategy is `.deferredToDate`,
/// which expects a NUMBER — so decoding an ISO string straight into a `Date`
/// throws. supabase-swift's `functions.invoke` uses exactly that plain decoder,
/// and a throw there is indistinguishable from a network failure at the call
/// site: the Card Ladder sales panel showed "Sales not loaded" and the price
/// went unavailable, for what was actually a well-formed 200 response
/// (2026-08-29).
///
/// So dates cross the wire as `String` and are converted here, deliberately, in
/// one place. Both shapes are accepted: Card Ladder sends fractional seconds
/// ("2026-08-28T15:04:10.000Z"), Postgres `timestamptz` often doesn't.
enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Nil for absent or unparseable input — a date we can't read is not a date,
    /// and inventing one would misdate a sale.
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return withFraction.date(from: raw) ?? plain.date(from: raw)
    }

    /// The other direction, for a timestamp we SEND (a lot claim's scanned_at).
    static func string(_ date: Date) -> String { withFraction.string(from: date) }
}
