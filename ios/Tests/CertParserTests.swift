import Testing
@testable import Slab3

struct CertParserTests {
    @Test func psaBareBarcodeIsEightDigits() {
        let r = CertParser.parse("49385027")
        #expect(r == CertScan(grader: .psa, certNumber: "49385027", raw: "49385027"))
    }

    @Test func cgcBareBarcodeIsTenDigits() {
        // Real CGC card certs (2026-08-22): 6055074171, 4274842001.
        #expect(CertParser.parse("6055074171")?.grader == .cgc)
        #expect(CertParser.parse("4274842001")?.grader == .cgc)
    }

    @Test func nineDigitStaysPSA() {
        // Future-proofing: PSA growing to 9 digits stays PSA, distinct from CGC's 10.
        #expect(CertParser.parse("123456789")?.grader == .psa)
    }

    @Test func psaQrUrlClassifiesByHost() {
        let r = CertParser.parse("https://www.psacard.com/cert/49385027")
        #expect(r?.grader == .psa)
        #expect(r?.certNumber == "49385027")
    }

    @Test func cgcQrUrlClassifiesByHost() {
        let r = CertParser.parse("https://www.cgccomics.com/certlookup/6055074171/")
        #expect(r?.grader == .cgc)
    }

    @Test func queryBasedQrUrlsExtractCert() {
        #expect(CertParser.parse("https://www.psacard.com/cert?certNumber=49385027")?.certNumber == "49385027")
        #expect(CertParser.parse("https://www.cgccards.com/certlookup/?cert=6055074171")?.grader == .cgc)
    }

    @Test func lookalikeDomainsAreRejected() {
        #expect(CertParser.parse("https://fakepsacard.com/cert/49385027") == nil)
        #expect(CertParser.parse("https://cgccards.com.example.test/cert/6055074171") == nil)
    }

    @Test func urlCertMustMatchGradersLength() {
        #expect(CertParser.parse("https://www.psacard.com/cert/123456") == nil)
        #expect(CertParser.parse("https://www.cgccards.com/certlookup/49385027") == nil)
    }

    @Test func rejectsGarbageAndWrongLengths() {
        #expect(CertParser.parse("") == nil)
        #expect(CertParser.parse("abc123") == nil)
        #expect(CertParser.parse("123456") == nil) // 6 digits: too short
        #expect(CertParser.parse("12345678901") == nil) // 11 digits: neither
    }

    @Test func trimsWhitespace() {
        #expect(CertParser.parse("  49385027 \n")?.certNumber == "49385027")
    }

}
