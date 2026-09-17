import Foundation
import SwiftData

/// Does inventory already hold this slab?
///
/// It exists as its own thing, rather than as a `first(where:)` over a screen's
/// `@Query`, because of what a `@Query` actually is: a value rendered into a view
/// when SwiftUI last updated it. The scanner hands its callback to the camera once
/// (`ScanScreen.onAppear`) and then fires it many times, so the card inserted two
/// hundred milliseconds ago may simply not be in that array yet — and the answer
/// "no such card" is then wrong in the one direction that costs a duplicate row.
///
/// A fetch against the context cannot miss it: `FetchDescriptor` includes pending
/// changes by default, so an inserted-but-unsaved card counts. That is the whole
/// point — at burst cadence nothing has been saved yet.
///
/// Identity is (grader, cert). The cert spaces are per-grader and the grader
/// itself is a GUESS inferred from digit count (`CertParser`), so both halves have
/// to match: a PSA and a CGC slab that happen to share a number are two cards.
enum CardLookup {
    static func existing(_ scan: CertScan, in context: ModelContext) -> Card? {
        // Bound outside the predicate: #Predicate captures values, not keypaths
        // into a struct it doesn't know how to translate.
        let grader = scan.grader.rawValue
        let cert = scan.certNumber
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate { $0.graderRaw == grader && $0.certNumber == cert }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
