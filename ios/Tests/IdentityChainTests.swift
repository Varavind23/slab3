import Testing
import Foundation
@testable import Slab3

/// The rule these lock in: a card's name and picture are assembled from three
/// sources that are all queried concurrently on a scan, so precedence has to be
/// STORED. Before this, whichever async task finished last won — a refresh could
/// replace a good PSA name with a Courtyard listing string, or drop an official
/// render back to the camera grab, and which one you got was a race.
@MainActor
struct IdentityChainTests {
    /// Deliberately unattached to a ModelContext: these are pure precedence
    /// rules, and a container would only add a lifetime to get wrong.
    private func makeCard() -> Card {
        Card(scan: CertScan(grader: .psa, certNumber: "49385027", raw: "49385027"))
    }

    // MARK: Identity precedence

    @Test func betterSourceOverwritesWorse() {
        let card = makeCard()
        card.setIdentity(name: "Charizard Listing", from: .courtyard)
        card.setIdentity(name: "Dark Slowbro-Holo", from: .psa)
        #expect(card.name == "Dark Slowbro-Holo")
        #expect(card.identitySource == .psa)
    }

    @Test func worseSourceCannotOverwriteBetter() {
        let card = makeCard()
        card.setIdentity(name: "Dark Slowbro-Holo", from: .psa)
        card.setIdentity(name: "Charizard Listing", from: .courtyard)
        #expect(card.name == "Dark Slowbro-Holo")
        #expect(card.identitySource == .psa, "a lower-ranked source must not demote the record")
    }

    /// The case that makes this a chain rather than a winner-takes-all: PSA
    /// answers with a subject but never a card number for some certs, and Card
    /// Ladder is the only source that answers for CGC at all.
    @Test func lowerSourceStillFillsGapsTheBetterOneLeft() {
        let card = makeCard()
        card.setIdentity(name: "Dark Slowbro-Holo", from: .psa)
        card.setIdentity(name: "Ignored", cardNumber: "12", from: .cardLadder)
        #expect(card.name == "Dark Slowbro-Holo", "the better name survives")
        #expect(card.cardNumber == "12", "but the gap gets filled")
    }

    @Test func emptyStringsAreNotIdentity() {
        let card = makeCard()
        card.setIdentity(name: "Dark Slowbro-Holo", from: .psa)
        card.setIdentity(name: "", title: "", from: .psa)
        #expect(card.name == "Dark Slowbro-Holo")
    }

    /// card_key is the spine — byte-identical across SQL, Swift and TS — and it
    /// is derived from `name`, so a name change that didn't refresh it would
    /// silently orphan the card's cached prices.
    @Test func nameChangeRefreshesCardKey() {
        let card = makeCard()
        let before = card.cardKey
        card.setIdentity(name: "Dark Slowbro-Holo", set: "Pokemon Rocket", from: .psa)
        #expect(card.cardKey != before)
        #expect(card.cardKey == CardKey.make(
            grader: .psa, set: "Pokemon Rocket", cardId: "Dark Slowbro-Holo", grade: nil
        ))
    }

    /// The long assembled title must never land in `name`, because that would
    /// rewrite card_key for every card.
    @Test func titleIsSeparateFromName() {
        let card = makeCard()
        card.setIdentity(name: "Dark Slowbro-Holo", title: "2000 Pokemon Rocket #12 Dark Slowbro-Holo", from: .psa)
        #expect(card.name == "Dark Slowbro-Holo")
        #expect(card.displayTitle == "Dark Slowbro-Holo", "the row shows the short one")
        #expect(!(card.cardKey.contains("2000")), "card_key must not absorb the title")
    }

    @Test func displayTitleFallsBackToTitleThenCert() {
        let card = makeCard()
        #expect(card.displayTitle == "PSA #49385027")
        card.setIdentity(title: "2000 Pokemon Rocket #12 Dark Slowbro-Holo", from: .cardLadder)
        #expect(card.displayTitle == "2000 Pokemon Rocket #12 Dark Slowbro-Holo")
    }

    @Test func metaLineCarriesTheCardNumber() {
        let card = makeCard()
        card.setIdentity(set: "Pokemon Rocket", year: 2000, cardNumber: "12", from: .psa)
        #expect(card.metaLine == "2000 Pokemon Rocket · #12")
    }

    // MARK: Image precedence

    @Test func officialImageReplacesCameraCapture() {
        let card = makeCard()
        card.setImage(Data("camera".utf8), from: .camera)
        card.setImage(Data("render".utf8), url: URL(string: "https://x/y.jpg"), from: .courtyard)
        #expect(card.thumbnailData == Data("render".utf8))
        #expect(card.imageUrl == "https://x/y.jpg")
    }

    @Test func cameraCaptureNeverClobbersAnOfficialImage() {
        let card = makeCard()
        card.setImage(Data("render".utf8), url: URL(string: "https://x/y.jpg"), from: .psa)
        card.setImage(Data("camera".utf8), from: .camera)
        #expect(card.thumbnailData == Data("render".utf8), "a later scan must not downgrade the picture")
        #expect(card.imageSource == .psa)
    }

    /// Courtyard's inline preview and its full render are the same rank, and the
    /// preview lands first on purpose — the second write has to be allowed.
    @Test func sameSourceMayReplaceItsOwnImage() {
        let card = makeCard()
        card.setImage(Data("lqip".utf8), url: URL(string: "https://x/y.jpg"), from: .courtyard)
        card.setImage(Data("full-render".utf8), url: URL(string: "https://x/y.jpg"), from: .courtyard)
        #expect(card.thumbnailData == Data("full-render".utf8))
    }

    @Test func emptyDataIsNeverStored() {
        let card = makeCard()
        card.setImage(Data("camera".utf8), from: .camera)
        card.setImage(Data(), from: .psa)
        #expect(card.thumbnailData == Data("camera".utf8))
        #expect(card.imageSource == .camera, "a failed download must not claim the slot")
    }
}
