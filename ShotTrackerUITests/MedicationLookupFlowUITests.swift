import XCTest

/// End-to-end verification of the Lookup-mode add flow (search → confirm variant →
/// save → drug info surfaces in detail) and medication deletion. Hits the real
/// RxTerms/openFDA APIs, so it's a live-network test — not meant for a CI gate, but a
/// direct exercise of the actual interactive path that can't be driven any other way
/// in this environment.
final class MedicationLookupFlowUITests: XCTestCase {
    private let searchTerm = "furosemide"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAddMedicationViaLookupThenDelete() throws {
        let app = XCUIApplication()
        app.launch()

        // Tab bar accessibility identifiers are applied to each tab's destination
        // view, not the synthesized tab bar button itself, so identifier-based
        // lookup doesn't find them — fall back to the stable label text here.
        app.buttons["Medications"].tap()
        app.buttons["button.addMedication"].tap()

        // Lookup mode is the default — the search field should already be visible.
        let searchField = app.textFields["field.medicationSearch"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText(searchTerm)

        let firstResult = app.buttons.matching(identifier: "row.medicationLookupResult").firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 15), "RxTerms search should return a result for '\(searchTerm)'")
        firstResult.tap()

        // A multi-variant result pushes a strength picker; a single-variant result
        // confirms immediately. Handle both.
        let variantRow = app.buttons.matching(identifier: "row.medicationLookupVariant").firstMatch
        if variantRow.waitForExistence(timeout: 3) {
            variantRow.tap()
        }

        let changeButton = app.buttons["Change"]
        XCTAssertTrue(changeButton.waitForExistence(timeout: 5), "Confirmed-selection card should appear after picking a variant")

        // Give the background openFDA drug-info fetch a moment to complete before
        // saving, so the detail view has something to surface.
        Thread.sleep(forTimeInterval: 3)

        app.buttons["button.saveMedication"].tap()

        let medicationRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", searchTerm)
        ).firstMatch
        XCTAssertTrue(medicationRow.waitForExistence(timeout: 5), "Newly added medication should appear in the list")
        medicationRow.tap()

        // Drug Info is conditional on whether the background fetch matched — don't
        // hard-fail the whole flow if openFDA had no data for this exact drug today,
        // but if the row is there, verify it actually opens and shows content.
        let drugInfoRow = app.staticTexts["Drug Info"]
        if drugInfoRow.waitForExistence(timeout: 2) {
            drugInfoRow.tap()
            XCTAssertTrue(app.navigationBars["Drug Info"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Delete the medication we just created and confirm it's gone.
        let deleteButton = app.buttons["button.deleteMedication"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        let confirmDelete = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()

        XCTAssertTrue(app.navigationBars["Medications"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", searchTerm)).firstMatch.exists,
            "Deleted medication should no longer appear in the list"
        )
    }
}
