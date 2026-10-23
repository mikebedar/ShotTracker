import XCTest

/// Verifies the fix for a live-hierarchy-dump-confirmed bug: a dose row's own
/// `AccessibilityID.scheduledDoseRow(id)` identifier, when applied to a container that
/// also encloses `DoseActionBar`'s Take/Snooze/Skip buttons, overrode those buttons'
/// individually-set identifiers in the XCUITest accessibility tree — making it
/// impossible to address "the Take button in row A" vs. "row B" by identifier when
/// multiple rows are on screen (the normal case). The fix moves the row identifier onto
/// a non-interactive sub-element that doesn't enclose the action buttons.
final class DoseRowAccessibilityUITests: XCTestCase {
    private let medicationName = "A11y Row Test Med \(UUID().uuidString.prefix(6))"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testActionButtonsResolveIndependentlyPerRowWhenMultipleRowsAreVisible() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Medications"].tap()
        app.buttons["button.addMedication"].tap()
        app.segmentedControls["button.addMedicationModeSwitcher"].buttons["Manual"].tap()

        let nameField = app.textFields.matching(identifier: "button.saveMedication.name").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(medicationName)

        app.buttons["button.saveMedication"].tap()

        let medicationRow = app.staticTexts[medicationName]
        XCTAssertTrue(medicationRow.waitForExistence(timeout: 5))
        medicationRow.tap()

        // A daily medication materializes many scheduled-dose rows, giving us multiple
        // simultaneous DoseActionBar instances to disambiguate — no need to depend on
        // time-of-day to get more than one actionable row on screen.
        app.buttons["Scheduled doses"].tap()

        let cells = app.cells
        XCTAssertTrue(cells.element(boundBy: 1).waitForExistence(timeout: 5), "Expected at least two scheduled dose rows for a daily medication")

        let firstCell = cells.element(boundBy: 0)
        let secondCell = cells.element(boundBy: 1)

        let firstTake = firstCell.buttons["Take"]
        let secondTake = secondCell.buttons["Take"]
        XCTAssertTrue(firstTake.exists)
        XCTAssertTrue(secondTake.exists)

        // Each Take button must carry its own per-dose identifier, not the row's.
        XCTAssertTrue(
            firstTake.identifier.hasPrefix("button.takeDose."),
            "Take button identifier should be its own (button.takeDose.<id>), not inherited from the row: got \(firstTake.identifier)"
        )
        XCTAssertTrue(secondTake.identifier.hasPrefix("button.takeDose."))

        // And rows must be distinguishable from one another.
        XCTAssertNotEqual(
            firstTake.identifier,
            secondTake.identifier,
            "Take buttons in different rows must resolve to distinct identifiers so tests can target a specific row"
        )

        // The row-level marker is still present (for existence/scroll-to checks) but is
        // a sibling of the action buttons now, not an ancestor — confirm it's distinct
        // from the button identifier rather than masking it.
        let firstRowMarker = firstCell.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row.scheduledDose.'"))
            .firstMatch
        XCTAssertTrue(firstRowMarker.exists)
        XCTAssertNotEqual(firstRowMarker.identifier, firstTake.identifier)
    }
}
