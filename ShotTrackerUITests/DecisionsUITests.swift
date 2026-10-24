import XCTest

/// The 2026-10-23 decisions, end to end over the demo data: "home · here" times when the
/// device is in another zone than a schedule's home, and a snooze that moves only that
/// dose (and can be taken back).
final class DecisionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func row(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row.scheduledDose.' AND label CONTAINS %@", text))
            .firstMatch
    }

    private func doseID(of row: XCUIElement) -> String {
        row.identifier.replacingOccurrences(of: "row.scheduledDose.", with: "")
    }

    @MainActor
    func testAwayFromHomeEveryDoseShowsBothClocks() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true, twoZones: true)

        // A specific time keeps both clocks: "Lisinopril, overdue, At 6:00 AM home time, 12:00 PM local time."
        let lisinopril = row(app, containing: "Lisinopril, overdue")
        XCTAssertTrue(lisinopril.waitForExistence(timeout: 10))
        XCTAssertTrue(lisinopril.label.contains("home time") && lisinopril.label.contains("local time"), lisinopril.label)

        // The medication says which clock it's on, and Edit can change it.
        app.tab("tab.medications").tap()
        app.staticTexts["Metformin"].firstMatch.tap()
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Home time zone: New York'")).firstMatch
        if !note.waitForExistence(timeout: 5) {
            print("TREE-DUMP\n" + app.debugDescription)
            XCTFail("No home time zone note on the detail screen")
        }

        app.buttons["Edit"].tap()
        let zoneRow = app.descendants(matching: .any).matching(identifier: "row.homeTimeZone").firstMatch
        XCTAssertTrue(app.scrollUntilHittable(zoneRow))
        XCTAssertTrue(zoneRow.label.contains("New York"), zoneRow.label)
        zoneRow.tap()
        XCTAssertTrue(app.navigationBars["Home Time Zone"].waitForExistence(timeout: 5))
        let paris = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Paris (Central European Time)'")).firstMatch
        XCTAssertTrue(paris.waitForExistence(timeout: 5), "The device's own zone is offered first")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Cancel"].tap()

        // Settings explains home zones.
        app.tab("tab.settings").tap()
        let device = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Paris (Central European Time)'")).firstMatch
        XCTAssertTrue(app.scrollUntilHittable(device), "Settings names this device's zone")
    }

    /// Named slots follow the device ("Morning (Paris)", "Home: Night"); one kept on home
    /// time says so ("Morning (home)", "Here: …"); Edit offers the choice.
    @MainActor
    func testAwayFromHomeSlotsFollowTheDevice() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true, twoZones: true)

        // "Metformin, due, Morning in Paris, anytime by 2:00 AM; at home it's night, by 8:00 PM Fri."
        let metformin = row(app, containing: "Metformin, due")
        XCTAssertTrue(metformin.waitForExistence(timeout: 10))
        XCTAssertTrue(metformin.label.contains("Morning in Paris") && metformin.label.contains("at home it's"), metformin.label)
        XCTAssertFalse(metformin.label.contains("local time"), metformin.label)
        let followsText = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Morning (Paris) · anytime by'")).firstMatch
        XCTAssertTrue(followsText.exists, "The card names the Paris clock")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Home: '")).firstMatch.exists, "…and home's")

        // Kept on home time: "Levothyroxine, due, Morning, home time, anytime by …; here it's …"
        let levothyroxine = row(app, containing: "Levothyroxine, due")
        XCTAssertTrue(app.scrollUntilHittable(levothyroxine), "The kept-home demo dose is due")
        XCTAssertTrue(levothyroxine.label.contains("Morning, home time") && levothyroxine.label.contains("here it's"), levothyroxine.label)

        // Edit: "When travelling" near the home time zone, set to Follows me for Metformin.
        for _ in 0..<6 { app.swipeDown() }
        app.tab("tab.medications").tap()
        app.staticTexts["Metformin"].firstMatch.tap()
        app.buttons["Edit"].tap()
        let picker = app.descendants(matching: .any).matching(identifier: "picker.travelPolicy").firstMatch
        XCTAssertTrue(app.scrollUntilHittable(picker))
        XCTAssertTrue(picker.label.contains("When travelling") || picker.value as? String == "Follows me" || picker.label.contains("Follows me"), "\(picker.label) \(String(describing: picker.value))")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Follows me'")).firstMatch.exists)
        app.buttons["Cancel"].tap()

        // Settings explains both.
        app.tab("tab.settings").tap()
        let footer = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Morning (Paris)'")).firstMatch
        XCTAssertTrue(app.scrollUntilHittable(footer), "Settings → Time Zones explains following")
    }

    @MainActor
    func testAtHomeTimesReadAsBefore() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true)
        let metformin = row(app, containing: "Metformin, due")
        XCTAssertTrue(metformin.waitForExistence(timeout: 10))
        XCTAssertFalse(metformin.label.contains("home time"), metformin.label)
        XCTAssertFalse(metformin.label.contains("in Paris") || metformin.label.contains("at home it's"), metformin.label)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Levothyroxine'")).firstMatch.exists, "The kept-home demo dose is only seeded away from home")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'local time'")).firstMatch.exists)
    }

    @MainActor
    func testSnoozeMovesOnlyThatDoseAndCanBeTakenBack() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true)

        let metformin = row(app, containing: "Metformin, due")
        XCTAssertTrue(metformin.waitForExistence(timeout: 10))
        let id = doseID(of: metformin)
        let snooze = app.buttons["button.snoozeDose.\(id)"]
        XCTAssertTrue(app.scrollUntilHittable(snooze))
        snooze.tap()
        XCTAssertTrue(app.staticTexts["Snoozed Metformin 20 min"].waitForExistence(timeout: 5))

        // The card says how long and when it reminds again, and offers Undo.
        let snoozedRow = app.descendants(matching: .any)["row.scheduledDose.\(id)"]
        XCTAssertTrue(snoozedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(snoozedRow.label.contains("snoozed") && snoozedRow.label.contains("Snoozed 20 min in all"), snoozedRow.label)
        let note = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Snoozed 20 min, reminder at'")).firstMatch
        XCTAssertTrue(note.exists, "Snooze footer on the card")
        let undo = app.buttons["button.undoDose.\(id)"]
        XCTAssertTrue(app.scrollUntilHittable(undo))
        undo.tap()
        XCTAssertTrue(app.staticTexts["Took back the snooze on Metformin"].waitForExistence(timeout: 5))
        let dueAgain = row(app, containing: "Metformin, due")
        for _ in 0..<6 where !dueAgain.exists { app.swipeDown() }
        XCTAssertTrue(dueAgain.waitForExistence(timeout: 5), "After taking the snooze back the dose is due again")
        XCTAssertFalse(dueAgain.label.contains("Snoozed"), dueAgain.label)

        // History logs both, and the demo's snoozed-then-late dose from yesterday.
        app.tab("tab.history").tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS 'Snoozed 20 min'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS 'Undone'")).firstMatch.exists)
        let late = any.matching(NSPredicate(format: "label CONTAINS 'Taken 15 min late, snoozed 20 min'")).firstMatch
        XCTAssertTrue(app.scrollUntilHittable(late), "Yesterday's snoozed dose reads as late, with its snooze")
    }
}
