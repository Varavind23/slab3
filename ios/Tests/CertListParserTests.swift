import Testing
import Foundation
import SwiftData
@testable import Slab3

/// A seller's cert list, read out of whatever they typed (owner ask, 2026-10-01).
/// The rules are the camera's (`CertParser`), so these pin the EXTRACTION: what
/// counts as a cert inside prose, and what is a grade, a year or a price.
struct CertListParserTests {
    private func certs(_ text: String) -> [String] { CertListParser.extract(text).map(\.certNumber) }
    private func graders(_ text: String) -> [Grader] { CertListParser.extract(text).map(\.grader) }

    @Test func onePerLine() {
        #expect(certs("49385027\n96679812\n6055074171") == ["49385027", "96679812", "6055074171"])
        #expect(graders("49385027\n6055074171") == [.psa, .cgc], "the camera's length rule")
    }

    @Test func commaAndSemicolonSeparated() {
        #expect(certs("49385027, 96679812;12345678 | 87654321") == ["49385027", "96679812", "12345678", "87654321"])
    }

    @Test func certsInsideSellerProse() {
        let list = """
        PSA 10 Charizard - 49385027 $1,250
        1999 Base Set Blastoise PSA 9 cert #96679812.
        CGC 9.5 Pikachu (cert:6055074171)
        """
        #expect(certs(list) == ["49385027", "96679812", "6055074171"],
                "grades, years and prices are not certs")
    }

    @Test func certURLs() {
        let list = """
        https://www.psacard.com/cert/49385027/psa
        https://www.cgccards.com/certlookup/6055074171/
        """
        #expect(certs(list) == ["49385027", "6055074171"])
        #expect(graders(list) == [.psa, .cgc])
    }

    /// CGC prints its cert 4-3-3, and a seller copying the label types it so.
    @Test func groupedCGCCertsAreJoined() {
        #expect(certs("6055 074 171") == ["6055074171"])
        #expect(certs("6055-074-171\n49385027") == ["6055074171", "49385027"])
        #expect(graders("6055 074 171") == [.cgc])
    }

    /// A newline separates two certs; it never glues a group together.
    @Test func groupingNeverCrossesALine() {
        #expect(certs("1234\n567\n890").isEmpty)
    }

    @Test func runsTooLongToBeACertAreIgnored() {
        #expect(certs("order 123456789012 shipped, cert 49385027") == ["49385027"])
    }

    @Test func duplicatesCollapseKeepingPasteOrder() {
        #expect(certs("96679812\n49385027\n96679812") == ["96679812", "49385027"])
    }

    @Test func nothingReadableIsEmpty() {
        #expect(certs("").isEmpty)
        #expect(certs("   \n ").isEmpty)
        #expect(certs("Charizard PSA 10, $500").isEmpty)
    }

    /// The single-cert sheet took any number before lists; an odd-length one
    /// typed alone still gets in, as PSA, for the chip to flip.
    @Test func aLoneOddLengthNumberIsStillAccepted() {
        let scans = CertListParser.extract(" 123456 ")
        #expect(scans.map(\.certNumber) == ["123456"])
        #expect(scans.map(\.grader) == [.psa])
        #expect(certs("123456\n49385027") == ["49385027"], "in a list, short numbers are not certs")
    }

    // MARK: CertBatch

    private func scan(_ cert: String) -> CertScan { CertScan(grader: .psa, certNumber: cert, raw: cert) }

    @Test func onlyNewCertsCountTowardTheCap() {
        let scans = (1...5).map { scan("1000000\($0)") }
        let held: Set<String> = ["10000001", "10000003"]
        let split = CertBatch.split(scans, cap: 2) { held.contains($0.certNumber) }
        #expect(split.held.map(\.certNumber) == ["10000001", "10000003"])
        #expect(split.add.map(\.certNumber) == ["10000002", "10000004"])
        #expect(split.over.map(\.certNumber) == ["10000005"])
    }

    @Test func theCapIsThirty() {
        let scans = (0..<34).map { scan(String(10_000_000 + $0)) }
        let split = CertBatch.split(scans) { _ in false }
        #expect(split.add.count == 30)
        #expect(split.over.count == 4)
    }

    // MARK: The sheet's pure parts

    @Test func aFlippedGraderAndARemovedCertApply() {
        let scans = ManualEntrySheet.scans(in: "49385027\n96679812", overrides: ["49385027": .cgc],
                                           excluded: ["96679812"])
        #expect(scans == [CertScan(grader: .cgc, certNumber: "49385027", raw: "49385027")])
    }

    @Test func theConfirmStatesTheOutcome() {
        let one = [scan("49385027")]
        #expect(ManualEntrySheet.confirmTitle(scans: one, split: CertBatch.Split(add: one)) == "Add card")
        #expect(ManualEntrySheet.confirmTitle(scans: one, split: CertBatch.Split(held: one)) == "Add card",
                "one held cert still goes through, to its duplicate readout, as it always did")
        let three = (1...3).map { scan("2000000\($0)") }
        #expect(ManualEntrySheet.confirmTitle(scans: three, split: CertBatch.Split(add: three)) == "Add 3 cards")
        #expect(ManualEntrySheet.confirmTitle(scans: three, split: CertBatch.Split(held: three)) == "Nothing new to add")
        #expect(ManualEntrySheet.confirmTitle(scans: three,
                                              split: CertBatch.Split(add: [three[0]], over: [three[1], three[2]]))
                == "Add first 1")
    }
}
