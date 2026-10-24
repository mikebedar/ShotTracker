import XCTest

/// End-to-end flows over the demo data set (`-seedDemoData`) and the stubbed network.
/// Every launch is a fresh in-memory store, so the tests don't depend on each other or
/// on whatever an earlier run left behind.
final class AppFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func row(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row.scheduledDose.' AND label CONTAINS %@", text))
            .firstMatch
    }

    private func scrollToTop(_ app: XCUIApplication, until element: XCUIElement) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeDown()
        }
    }

    private func doseID(of row: XCUIElement) -> String {
        row.identifier.replacingOccurrences(of: "row.scheduledDose.", with: "")
    }

    @MainActor
    func testEveryTabOpensItsScreen() throws {
        let app = XCUIApplication.launchedForTesting()
        for (tab, title) in [("tab.medications", "Medications"), ("tab.history", "History"), ("tab.settings", "Settings"), ("tab.today", "Today")] {
            XCTAssertTrue(app.tab(tab).waitForExistence(timeout: 10))
            app.tab(tab).tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(tab) didn't open \(title)")
        }
    }

    @MainActor
    func testTakeUndoAndSnoozeOnlyWhereItMeansSomething() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true)

        // Metformin's demo window is open now → due → Take / Snooze / Skip.
        let metformin = row(app, containing: "Metformin, due")
        XCTAssertTrue(metformin.waitForExistence(timeout: 10))
        let id = doseID(of: metformin)
        XCTAssertTrue(app.buttons["button.snoozeDose.\(id)"].exists, "A due dose offers Snooze")

        // Vitamin D is upcoming (an hour from now) → Take / Skip, but no Snooze.
        let vitaminD = row(app, containing: "Vitamin D, upcoming")
        if app.scrollUntilHittable(vitaminD) {
            let upcomingID = doseID(of: vitaminD)
            XCTAssertTrue(app.buttons["button.takeDose.\(upcomingID)"].exists)
            XCTAssertFalse(app.buttons["button.snoozeDose.\(upcomingID)"].exists, "Snoozing an upcoming dose would pull it earlier")
        }

        let take = app.buttons["button.takeDose.\(id)"]
        scrollToTop(app, until: take)
        XCTAssertTrue(app.scrollUntilHittable(take))
        take.tap()
        XCTAssertTrue(app.staticTexts["Marked Metformin as taken"].waitForExistence(timeout: 5))

        let undo = app.buttons["button.undoDose.\(id)"]
        XCTAssertTrue(
            app.scrollUntilHittable(undo),
            "The taken dose shows an Undo button: \(app.buttons.matching(NSPredicate(format: "label == 'Undo'")).allElementsBoundByIndex.map(\.identifier))"
        )
        undo.tap()
        XCTAssertTrue(app.staticTexts["Undid Metformin"].waitForExistence(timeout: 5))
        // The card moves back up to Take Now (out of the lazy stack's built range).
        let takeAgain = app.buttons["button.takeDose.\(id)"]
        scrollToTop(app, until: takeAgain)
        XCTAssertTrue(takeAgain.exists, "After Undo the dose is takeable again")
    }

    /// The toast's Undo (Atelier's presenter) reverts a Take through the same path as the card's Undo.
    @MainActor
    func testToastUndoRevertsATake() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true)
        let metformin = row(app, containing: "Metformin, due")
        XCTAssertTrue(metformin.waitForExistence(timeout: 10))
        let id = doseID(of: metformin)
        let take = app.buttons["button.takeDose.\(id)"]
        XCTAssertTrue(app.scrollUntilHittable(take))
        take.tap()
        XCTAssertTrue(app.staticTexts["Marked Metformin as taken"].waitForExistence(timeout: 5))

        let toastUndo = app.buttons.matching(NSPredicate(format: "label == 'Undo' AND NOT (identifier BEGINSWITH 'button.undoDose.')")).firstMatch
        XCTAssertTrue(toastUndo.waitForExistence(timeout: 5), "The toast offers Undo")
        toastUndo.tap()

        let takeAgain = app.buttons["button.takeDose.\(id)"]
        scrollToTop(app, until: takeAgain)
        XCTAssertTrue(takeAgain.waitForExistence(timeout: 5), "After the toast's Undo the dose is takeable again")
    }

    @MainActor
    func testLoggingARefillUpdatesSupply() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true)
        app.tab("tab.medications").tap()
        app.staticTexts["Lisinopril"].firstMatch.tap()

        let logRefill = app.buttons["Log refill"]
        XCTAssertTrue(logRefill.waitForExistence(timeout: 5))
        logRefill.tap()
        let alert = app.alerts["Log refill"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Add"].tap()

        let total = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "97 tablets total")).firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 5), "7 on hand + a 90-tablet bottle")
    }

    @MainActor
    func testTakingARollingDoseTooSoonWarns() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true)
        app.tab("tab.medications").tap()
        app.staticTexts["Ozempic"].firstMatch.tap()
        app.buttons["Scheduled doses"].tap()

        let take = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'button.takeDose.'")).firstMatch
        XCTAssertTrue(take.waitForExistence(timeout: 5))
        take.tap()

        // The next dose is now a week out; taking it right away is inside the minimum.
        let next = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'button.takeDose.'")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()
        let warning = app.alerts["Take dose early?"]
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.buttons["Take Anyway"].exists)
        warning.buttons["Cancel"].tap()
    }

    @MainActor
    func testCalendarKeepsTodaysTakenDoses() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true)
        let switcher = app.segmentedControls["button.todayViewModeSwitcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 10))
        switcher.buttons["Calendar"].tap()

        XCTAssertTrue(app.otherElements["view.todayCalendar"].waitForExistence(timeout: 5)
                      || app.descendants(matching: .any)["view.todayCalendar"].waitForExistence(timeout: 5))
        // The demo's Vitamin B12 dose was taken today; it used to vanish from the day list.
        let b12 = app.staticTexts["Vitamin B12"].firstMatch
        XCTAssertTrue(app.scrollUntilHittable(b12), "Today's taken dose should still be listed in calendar mode")
    }

    @MainActor
    func testSettingsShowsPermissionStateAndNoDeadSyncToggle() throws {
        let app = XCUIApplication.launchedForTesting()
        app.tab("tab.settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let permission = app.buttons["Allow Notifications"].exists
            || app.staticTexts["Notifications are allowed"].exists
            || app.staticTexts["Notifications are turned off for ShotTracker"].exists
        XCTAssertTrue(permission, "Settings should say whether reminders can arrive")
        XCTAssertFalse(app.switches["Enable iCloud Sync"].exists)
    }

    @MainActor
    func testPhasedScheduleCanBeCreated() throws {
        let app = XCUIApplication.launchedForTesting()
        app.tab("tab.medications").tap()
        app.buttons["button.addMedication"].tap()
        app.segmentedControls["button.addMedicationModeSwitcher"].buttons["Manual"].tap()
        let nameField = app.textFields.matching(identifier: "button.saveMedication.name").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Taper Test\n")  // Return dismisses the keyboard
        let frequency = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Frequency'")).firstMatch
        if !app.scrollUntilHittable(frequency) {
            print("TREE-DUMP\n" + app.debugDescription)
            XCTFail("No Frequency picker")
        }
        frequency.tap()
        let phased = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Phased'")).firstMatch
        if !phased.waitForExistence(timeout: 5) {
            print("TREE-DUMP\n" + app.debugDescription)
            XCTFail("No Phased option")
        }
        phased.tap()

        let addPhase = app.buttons["Add Phase"]
        XCTAssertTrue(app.scrollUntilHittable(addPhase))
        addPhase.tap()
        app.saveMedication()

        app.staticTexts["Taper Test"].firstMatch.tap()
        let summary = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Phase 1: daily, 7 days")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
    }
}
