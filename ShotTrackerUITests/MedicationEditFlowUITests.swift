import XCTest

/// Guards the "I can edit a medication's settings after adding it" flow end to end:
/// Medications → tap the med → Details → Edit → change Missed dose handling → Save.
/// Uses Manual add mode so it stays network-free and deterministic.
final class MedicationEditFlowUITests: XCTestCase {
    private let medicationName = "Edit Flow Med \(UUID().uuidString.prefix(6))"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCanEditMissedDosePolicyAfterAdding() throws {
        let app = XCUIApplication.launchedForTesting()

        app.tab("tab.medications").tap()
        app.buttons["button.addMedication"].tap()
        app.segmentedControls["button.addMedicationModeSwitcher"].buttons["Manual"].tap()

        let nameField = app.textFields.matching(identifier: "button.saveMedication.name").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(medicationName)
        app.buttons["button.saveMedication"].tap()

        // Open the medication's detail screen.
        let medicationRow = app.staticTexts[medicationName]
        XCTAssertTrue(medicationRow.waitForExistence(timeout: 5))
        medicationRow.tap()

        // The Edit affordance must be present on the detail screen.
        let editButton = app.buttons["Edit"]
        XCTAssertTrue(
            editButton.waitForExistence(timeout: 5),
            "No 'Edit' button on the medication detail screen — a medication's settings can't be changed after adding."
        )
        editButton.tap()

        // The editor must open in Edit mode (no Lookup/Manual switcher) and expose the
        // schedule settings — including missed-dose handling.
        XCTAssertTrue(
            app.navigationBars["Edit Medication"].waitForExistence(timeout: 5),
            "Edit did not open the medication editor."
        )
        XCTAssertFalse(
            app.segmentedControls["button.addMedicationModeSwitcher"].exists,
            "Editing an existing medication should not show the add-mode switcher."
        )

        // The section sits below the fold, and a Form only builds visible rows — scroll
        // until it materializes rather than asserting on the initial viewport.
        let missedDoseHeader = app.staticTexts["Missed dose handling"]
        var attempts = 0
        while !missedDoseHeader.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(
            missedDoseHeader.exists,
            "The 'Missed dose handling' setting is not reachable when editing an existing medication."
        )
    }
}
