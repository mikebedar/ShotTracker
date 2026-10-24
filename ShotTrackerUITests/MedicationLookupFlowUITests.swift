import XCTest

/// The Lookup-mode add flow (search → pick a strength → save → drug info in detail) and
/// deletion, against canned RxTerms/openFDA answers (`-uiTestStubNetwork`) — deterministic
/// and offline. It used to hit the live APIs.
final class MedicationLookupFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAddMedicationViaLookupThenDelete() throws {
        let app = XCUIApplication.launchedForTesting()
        app.tab("tab.medications").tap()
        app.buttons["button.addMedication"].tap()

        // Lookup mode is the default — the search field should already be visible.
        let searchField = app.textFields["field.medicationSearch"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("furosemide")

        // The stub answers with an oral pill (two strengths) and an injectable.
        let firstResult = app.buttons.matching(identifier: "row.medicationLookupResult").firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 10))
        firstResult.tap()

        let variantRow = app.buttons.matching(identifier: "row.medicationLookupVariant").firstMatch
        XCTAssertTrue(variantRow.waitForExistence(timeout: 5), "A two-strength result pushes the strength picker")
        variantRow.tap()

        XCTAssertTrue(app.buttons["Change"].waitForExistence(timeout: 5), "Confirmed-selection card should appear after picking a variant")
        app.saveMedication()

        let medicationRow = app.staticTexts["FUROSEMIDE"].firstMatch
        XCTAssertTrue(medicationRow.waitForExistence(timeout: 5), "Newly added medication should appear in the list")
        medicationRow.tap()

        let drugInfoRow = app.buttons["Drug Info"].firstMatch
        XCTAssertTrue(drugInfoRow.waitForExistence(timeout: 5), "The stubbed openFDA label should surface as Drug Info")
        drugInfoRow.tap()
        XCTAssertTrue(app.staticTexts["Stub boxed warning."].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let deleteButton = app.buttons["button.deleteMedication"]
        XCTAssertTrue(app.scrollUntilHittable(deleteButton))
        deleteButton.tap()
        let confirmDelete = app.alerts.buttons["Delete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5))
        confirmDelete.tap()

        XCTAssertTrue(app.navigationBars["Medications"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["FUROSEMIDE"].exists, "Deleted medication should no longer appear in the list")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archived'")).firstMatch.exists)
    }

    @MainActor
    func testLookupExplainsNoMatchesAndOutages() throws {
        let app = XCUIApplication.launchedForTesting()
        app.tab("tab.medications").tap()
        app.buttons["button.addMedication"].tap()

        let searchField = app.textFields["field.medicationSearch"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("zzz")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No matches'")).firstMatch.waitForExistence(timeout: 5))

        searchField.clearAndType("offline")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Search is unavailable'")).firstMatch.waitForExistence(timeout: 5))
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
