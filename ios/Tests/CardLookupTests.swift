import Testing
import Foundation
import SwiftData
@testable import Slab3

/// The duplicate guard, pinned against the failure it was rewritten for: one slab
/// reaching the recent list twice while the camera ran at burst cadence.
///
/// Unlike the rest of this suite these tests need a real store, because the whole
/// question is what the STORE says versus what a view has rendered. It is
/// in-memory, so nothing touches the device's inventory.
@MainActor
struct CardLookupTests {
    private let psa = CertScan(grader: .psa, certNumber: "49385027", raw: "49385027")

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Card.self, Folder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// THE regression. The check used to run against `ScanScreen`'s `@Query`
    /// snapshot, which does not contain a card inserted since SwiftUI last
    /// updated the view — and at scan cadence nothing has been saved yet either.
    /// A second read of the same slab arriving in that gap found nothing and
    /// inserted a second card.
    @Test func findsACardInsertedButNotYetSaved() throws {
        let context = try makeContext()
        context.insert(Card(scan: psa))
        let found = CardLookup.existing(psa, in: context)
        #expect(found?.certNumber == "49385027", "an unsaved insert still counts as in inventory")
    }

    @Test func emptyInventoryMatchesNothing() throws {
        let context = try makeContext()
        let found = CardLookup.existing(psa, in: context)
        #expect(found == nil)
    }

    @Test func aDifferentCertIsADifferentCard() throws {
        let context = try makeContext()
        context.insert(Card(scan: CertScan(grader: .psa, certNumber: "82031277", raw: "82031277")))
        let found = CardLookup.existing(psa, in: context)
        #expect(found == nil)
    }

    /// Cert spaces are per-grader, and the grader is inferred from digit count —
    /// so the same digits under the other grader must not read as the same slab.
    @Test func theSameNumberUnderAnotherGraderIsADifferentCard() throws {
        let context = try makeContext()
        context.insert(Card(scan: CertScan(grader: .cgc, certNumber: "49385027", raw: "49385027")))
        let found = CardLookup.existing(psa, in: context)
        #expect(found == nil)
    }

    /// A deliberate rescan has to keep finding the card after the store settles —
    /// that is what turns the second sighting into the amber "already in
    /// inventory" readout rather than a new row.
    @Test func stillFoundAfterASave() throws {
        let context = try makeContext()
        context.insert(Card(scan: psa))
        try context.save()
        let found = CardLookup.existing(psa, in: context)
        #expect(found != nil)
    }
}
