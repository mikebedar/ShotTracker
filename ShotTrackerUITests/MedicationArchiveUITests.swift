import XCTest

/// Verifies the actual point of archiving: a medication's dose history survives even
/// after it's "deleted." Uses Manual add mode (no live network) so this stays fast
/// and deterministic, unlike the Lookup-mode flow test.
final class MedicationArchiveUITests: XCTestCase {
    private let medicationName = "Archive Test Med \(UUID().uuidString.prefix(6))"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testArchivedMedicationKeepsHistoryButLeavesActiveList() throws {
        let app = XCUIApplication.launchedForTesting()

        app.tab("tab.medications").tap()
        app.buttons["button.addMedication"].tap()

        // Switch to Manual mode to avoid any live-network dependency in this test.
        app.segmentedControls["button.addMedicationModeSwitcher"].buttons["Manual"].tap()

        let nameField = app.textFields.matching(identifier: "button.saveMedication.name").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(medicationName)

        app.saveMedication()

        let medicationRow = app.staticTexts[medicationName]
        XCTAssertTrue(medicationRow.waitForExistence(timeout: 5))
        medicationRow.tap()

        // Take today's dose so there's a real DoseEvent to check for survival. Match by
        // label rather than the per-dose identifier, since we only need "the first Take
        // button" here — rows are chronological, so the first one is today's.
        app.buttons["Scheduled doses"].tap()
        let takeButton = app.buttons.matching(NSPredicate(format: "label == %@", "Take")).firstMatch
        XCTAssertTrue(takeButton.waitForExistence(timeout: 5), "Newly added daily medication should have a scheduled dose today")
        takeButton.tap()
        // The Take's toast floats above the tab bar, over the bottom of the list, where Delete is: let it go first.
        let taken = app.staticTexts["Marked \(medicationName) as taken"]
        XCTAssertTrue(taken.waitForExistence(timeout: 5))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: taken)
        wait(for: [gone], timeout: 15)

        // Back to the medication detail, then archive it.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let deleteButton = app.buttons["button.deleteMedication"]
        // The last row of a lazy List: scroll to it (the "How this schedule works" section is above it).
        XCTAssertTrue(app.scrollUntilHittable(deleteButton))
        // No confirmation alert: deleting archives it and the toast offers Undo.
        deleteButton.tap()
        XCTAssertTrue(app.staticTexts["Archived \(medicationName)"].waitForExistence(timeout: 5))

        // Gone from the active medications list.
        XCTAssertTrue(app.navigationBars["Medications"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts[medicationName].waitForExistence(timeout: 2),
            "Archived medication should no longer appear in the active medications list"
        )

        // Still present in History.
        app.tab("tab.history").tap()
        let historyEntry = app.staticTexts[medicationName]
        XCTAssertTrue(historyEntry.waitForExistence(timeout: 5), "Archived medication's dose history should still appear in History")
    }

    /// Delete from the list's swipe, then Undo in the toast: the medication is back in the active list.
    @MainActor
    func testDeleteIsUndoable() throws {
        let app = XCUIApplication.launchedForTesting()
        app.addManualMedication(named: medicationName)

        let row = app.staticTexts[medicationName]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'button.deleteMedication.'")).firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()

        XCTAssertTrue(app.staticTexts["Archived \(medicationName)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[medicationName].waitForExistence(timeout: 2), "Gone from the active list")
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(app.staticTexts[medicationName].waitForExistence(timeout: 5), "Undo brings it back")
    }
}
