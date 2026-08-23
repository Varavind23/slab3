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
}
