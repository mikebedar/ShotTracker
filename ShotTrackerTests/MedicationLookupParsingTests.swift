import Testing
@testable import ShotTracker

struct MedicationLookupParsingTests {
    @Test func zipsStrengthsWithMatchingRxcuis() {
        let variants = MedicationLookupService.parseVariants(
            strengthsAndForms: ["  500 mg Tab", "1,000 mg Tab"],
            rxcuis: ["861007", "861004"]
        )

        #expect(variants.map(\.strengthAndForm) == ["500 mg Tab", "1,000 mg Tab"])
        #expect(variants.map(\.rxcui) == ["861007", "861004"])
    }

    @Test func trimsLeadingWhitespaceFromStrengthStrings() {
        // RxTerms right-aligns strengths for column display (e.g. "  500 mg Tab" next
        // to "1,000 mg Tab"), which reads as stray whitespace once it's in a UI list.
        let variants = MedicationLookupService.parseVariants(
            strengthsAndForms: ["  500 mg Tab"],
            rxcuis: ["861007"]
        )
        #expect(variants.first?.strengthAndForm == "500 mg Tab")
    }

    @Test func toleratesShorterRxcuisArray() {
        // A row can have more strengths than resolved RXCUIS (a code that didn't
        // resolve) — missing entries should leave rxcui nil, not drop the strength.
        let variants = MedicationLookupService.parseVariants(
            strengthsAndForms: ["500 mg Tab", "625 mg Tab", "750 mg Tab"],
            rxcuis: ["861007"]
        )

        #expect(variants.count == 3)
        #expect(variants[0].rxcui == "861007")
        #expect(variants[1].rxcui == nil)
        #expect(variants[2].rxcui == nil)
    }

    @Test func toleratesEmptyRxcuisArray() {
        let variants = MedicationLookupService.parseVariants(
            strengthsAndForms: ["500 mg Tab"],
            rxcuis: []
        )
        #expect(variants.count == 1)
        #expect(variants[0].rxcui == nil)
    }

    @Test func emptyStrengthsProducesNoVariants() {
        let variants = MedicationLookupService.parseVariants(strengthsAndForms: [], rxcuis: ["861007"])
        #expect(variants.isEmpty)
    }
}
