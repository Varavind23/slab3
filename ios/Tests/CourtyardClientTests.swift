import Testing
@testable import Slab3

struct CourtyardClientTests {
    @Test func gradeNumberExtractsLeadingNumber() {
        #expect(CourtyardClient.gradeNumber("10 GEM MINT") == "10")
        #expect(CourtyardClient.gradeNumber("PSA 9") == "9")
        #expect(CourtyardClient.gradeNumber("9.5") == "9.5")
        #expect(CourtyardClient.gradeNumber("MINT 9") == "9")
        #expect(CourtyardClient.gradeNumber("AUTH") == nil)
        #expect(CourtyardClient.gradeNumber(nil) == nil)
    }

    /// Courtyard names the card under a CATEGORY-dependent metadata key —
    /// `Title/PKMN` on Pokémon records, `Title/Subject` elsewhere. Reading one
    /// spelling meant Pokémon, the app's main category, never got a name from
    /// Courtyard; it fell through to the long listing headline, which then fed
    /// card_key via `name`.
    @Test func shortNameIsFoundUnderAnyCategoryTitleKey() {
        #expect(CourtyardClient.shortName(in: ["Title/PKMN": "Charizard", "Set": "Base Set"]) == "Charizard")
        #expect(CourtyardClient.shortName(in: ["Title/Subject": "Kevin McHale"]) == "Kevin McHale")
    }

    @Test func shortNameIsNilRatherThanTheListingHeadline() {
        // No Title/ key: the caller must fall back deliberately, not silently
        // adopt a 12-word marketplace headline as the card's name.
        #expect(CourtyardClient.shortName(in: ["Set": "Base Set", "Card Number": "4"]) == nil)
    }
}
