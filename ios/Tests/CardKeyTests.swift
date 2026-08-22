import Testing
@testable import Slab3

/// Parity with the SQL make_card_key (supabase/migrations). These vectors must
/// match the SQL test's expectations exactly — the same card_key on client and
/// server is what makes the sale-limit count and price matching agree.
struct CardKeyTests {
    @Test func matchesSqlNormalization() {
        #expect(
            CardKey.make(grader: .psa, set: "1999 Pokemon Base Set", cardId: "Charizard #4", grade: "PSA 9")
                == "psa:1999-pokemon-base-set:charizard-4:psa-9"
        )
    }

    @Test func whitespaceCasePunctuationStable() {
        let a = CardKey.make(grader: .psa, set: "1999  Pokemon   Base Set", cardId: "Charizard #4", grade: "PSA 9")
        let b = CardKey.make(grader: .psa, set: "1999 pokemon base set", cardId: "charizard  #4", grade: "psa 9")
        #expect(a == b)
    }

    @Test func graderIsPartOfKey() {
        let psa = CardKey.make(grader: .psa, set: "Base Set", cardId: "Charizard", grade: "9")
        let cgc = CardKey.make(grader: .cgc, set: "Base Set", cardId: "Charizard", grade: "9")
        #expect(psa != cgc)
    }

    @Test func emptySegmentsBecomeEmpty() {
        #expect(CardKey.make(grader: .cgc, set: nil, cardId: "6055074171", grade: nil) == "cgc::6055074171:")
    }
}
