import Foundation
import SwiftUI
import Testing
@testable import Slab3

/// The confidence meter is per-source: Card Ladder draws five segments because
/// Card Ladder states five steps, Courtyard draws three because its own app only
/// ever says low / medium / high. Two things are asserted here because both have
/// been got wrong by eye before — the bucketing (a 3 must not read as "high") and
/// the geometry (both meters must be exactly as wide, or the right edge of a row
/// goes ragged when the source toggle flips).
struct ConfidenceMeterTests {

    @Test func cardLadderKeepsFiveSegments() {
        #expect(PriceSource.cl.confidenceSegments == 5)
        for v in 0...5 {
            #expect(PriceSource.cl.confidenceLevel(v) == v)
        }
    }

    @Test func courtyardBucketsFiveIntoThree() {
        #expect(PriceSource.cy.confidenceSegments == 3)
        // 0 is "no basis at all" and stays empty; 1 low, 2–3 medium, 4–5 high —
        // the same split Courtyard's app shows beside the price.
        #expect(PriceSource.cy.confidenceLevel(0) == 0)
        #expect(PriceSource.cy.confidenceLevel(1) == 1)
        #expect(PriceSource.cy.confidenceLevel(2) == 2)
        #expect(PriceSource.cy.confidenceLevel(3) == 2)
        #expect(PriceSource.cy.confidenceLevel(4) == 3)
        #expect(PriceSource.cy.confidenceLevel(5) == 3)
    }

    @Test func outOfRangeConfidenceIsClamped() {
        #expect(PriceSource.cy.confidenceLevel(9) == 3)
        #expect(PriceSource.cy.confidenceLevel(-1) == 0)
        #expect(PriceSource.cl.confidenceLevel(9) == 5)
    }

    /// Three segments and five segments must fill the same 43pt slot.
    @Test func bothMetersAreTheSameWidth() {
        for segments in [3, 5] {
            let w = ConfidenceMeter.segmentWidth(segments: segments)
            let total = w * CGFloat(segments) + ConfidenceMeter.gap * CGFloat(segments - 1)
            #expect(abs(total - ConfidenceMeter.totalWidth) < 0.001)
        }
        // And the five-segment meter is unchanged: 7pt segments, as laid out.
        #expect(abs(ConfidenceMeter.segmentWidth(segments: 5) - 7) < 0.001)
    }

    /// A three-segment meter must land on the same three tones a five-segment one
    /// does, or CY's "medium" would be coloured like CL's "high".
    @Test func tonesMatchAcrossBothScales() {
        #expect(Caliper.confidence(1, of: 3) == Caliper.confidence(1, of: 5)) // low
        #expect(Caliper.confidence(2, of: 3) == Caliper.confidence(3, of: 5)) // medium
        #expect(Caliper.confidence(3, of: 3) == Caliper.confidence(5, of: 5)) // high
        #expect(Caliper.isHighConfidence(3, of: 3))
        #expect(!Caliper.isHighConfidence(2, of: 3))
        #expect(Caliper.isHighConfidence(4, of: 5))
        #expect(!Caliper.isHighConfidence(3, of: 5))
    }
}
