import XCTest

/// Verifies the Missed dose handling UI: the section renders and an injection
/// smart-defaults to "Reschedule from last dose". Manual mode only — no live network.
/// The Advanced minimum-interval control and the underlying policy math are covered by
/// the unit tests (`DoseReschedulingTests`); this guards the UI wiring.
final class MissedDosePolicyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testInjectionDefaultsToRescheduleFromLastDose() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Medications"].tap()
        app.buttons["button.addMedication"].tap()
        app.segmentedControls["button.addMedicationModeSwitcher"].buttons["Manual"].tap()

        let nameField = app.textFields.matching(identifier: "button.saveMedication.name").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Test Injection")

        // Dismiss the keyboard so the lower form sections scroll reliably.
        app.buttons["Injection"].firstMatch.tap()

        // The Missed dose handling section's explanatory text (a case-preserved StaticText)
        // being the rescheduling preset's proves the injection defaulted correctly.
        let rescheduleExplanation = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "keeping a steady interval")
        ).firstMatch
        XCTAssertTrue(scrollUntilVisible(rescheduleExplanation, in: app),
                      "Injection should default to Reschedule-from-last-dose and show its explanation")
    }

    @MainActor
    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}
