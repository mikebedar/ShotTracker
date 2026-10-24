import XCTest

/// "When you travel" (2026-10-23, branch `travel-options`): setting up a medication with
/// non-default travel choices shows them in the live example, in the save confirmation and
/// on the detail screen; an away-from-home run honours them.
final class TravelOptionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func any(_ app: XCUIApplication, labelContains text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func option(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// Adds "Travel Pill" (a daily morning pill, home New York) choosing at least 20 hours
    /// and move-now; stops on the confirmation step.
    @MainActor
    private func setUpTravelPill(_ app: XCUIApplication, shot: (String) -> Void = { _ in }) {
        app.tab("tab.medications").tap()
        app.buttons["button.addMedication"].tap()
        app.segmentedControls["button.addMedicationModeSwitcher"].buttons["Manual"].tap()
        let nameField = app.textFields.matching(identifier: "button.saveMedication.name").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("Travel Pill")
        app.buttons["Oral"].firstMatch.tap()   // dismisses the keyboard

        // The defaults for a daily pill: follows me, by calendar day, finish on the old clock.
        let follows = option(app, "Follows me")
        XCTAssertTrue(app.scrollUntilHittable(follows, maxSwipes: 14))
        XCTAssertTrue(follows.isSelected)
        let byDay = option(app, "Count by calendar day")
        XCTAssertTrue(app.scrollUntilHittable(byDay))
        XCTAssertTrue(byDay.isSelected)

        let hours = option(app, "Keep at least 20 hours between doses")
        XCTAssertTrue(app.scrollUntilHittable(hours))
        hours.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "stepper.travelHours").firstMatch.waitForExistence(timeout: 5))
        let move = option(app, "Move it to the new clock now")
        XCTAssertTrue(app.scrollUntilHittable(move))
        move.tap()
        XCTAssertTrue(move.isSelected)

        // The live example, computed for a trip to Paris (the default from New York).
        let example = app.descendants(matching: .any).matching(identifier: "text.travelExample").firstMatch
        XCTAssertTrue(app.scrollUntilHittable(example))
        XCTAssertTrue(example.label.contains("If you fly from New York to Paris"), example.label)
        XCTAssertTrue(example.label.contains("instead of"), "The next dose waits 20 hours: \(example.label)")
        XCTAssertTrue(example.label.contains("it switches to Paris time"), "Move now: \(example.label)")
        shot("travel-01-example")

        app.buttons["button.saveMedication"].tap()
        let confirm = app.buttons["button.confirmSaveMedication"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Saving a new schedule shows how it works first")
    }

    @MainActor
    func testNonDefaultTravelChoicesShowInTheExampleTheConfirmationAndTheDetail() throws {
        let app = XCUIApplication.launchedForTesting(deviceTimeZone: "America/New_York")
        setUpTravelPill(app)

        XCTAssertTrue(any(app, labelContains: "waits until at least 20 hours after the last").exists, "Confirmation: the hours choice")
        XCTAssertTrue(any(app, labelContains: "moves to the local clock at once").exists, "Confirmation: the landing choice")
        XCTAssertTrue(any(app, labelContains: "Every day: Morning anytime").exists, "Confirmation: the timing")

        // Keep Editing goes back to the form with nothing saved; Save then saves.
        app.buttons["button.keepEditing"].tap()
        XCTAssertTrue(app.navigationBars["Add Medication"].waitForExistence(timeout: 5))
        app.saveMedication()

        let row = app.staticTexts["Travel Pill"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let detail = any(app, labelContains: "waits until at least 20 hours after the last")
        XCTAssertTrue(app.scrollUntilHittable(detail), "Detail: How this schedule works")
        XCTAssertTrue(any(app, labelContains: "moves to the local clock at once").exists)

        // Editing back to the defaults is a schedule change: it asks again.
        app.buttons["Edit"].tap()
        let byDay = option(app, "Count by calendar day")
        XCTAssertTrue(app.scrollUntilHittable(byDay, maxSwipes: 14))
        byDay.tap()
        app.buttons["button.saveMedication"].tap()
        XCTAssertTrue(app.buttons["button.confirmSaveMedication"].waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, labelContains: "One of each per calendar day").exists)
        app.buttons["button.confirmSaveMedication"].tap()
        XCTAssertTrue(any(app, labelContains: "One of each per calendar day").waitForExistence(timeout: 5))
    }

    /// Demo planned in New York, the phone now in Paris (`-demoTrip`): Malarone (at least
    /// 20 hours) waits; Doxycycline (move now) is already on the Paris clock.
    @MainActor
    func testAwayFromHomeTheChoicesAreHonoured() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true, twoZones: true, trip: true)

        let malarone = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row.scheduledDose.' AND label BEGINSWITH 'Malarone, upcoming'")).firstMatch
        XCTAssertTrue(app.scrollUntilHittable(malarone), "Malarone's next dose is held back")
        XCTAssertTrue(malarone.label.contains("Morning in Paris"), malarone.label)
        XCTAssertTrue(malarone.label.contains("20 hours after your last dose"), malarone.label)

        for _ in 0..<6 { app.swipeDown() }
        let doxycycline = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row.scheduledDose.' AND label BEGINSWITH 'Doxycycline, upcoming'")).firstMatch
        XCTAssertTrue(app.scrollUntilHittable(doxycycline), "Doxycycline's open Dubai dose moved to Paris")
        XCTAssertTrue(doxycycline.label.contains("Morning in Paris"), doxycycline.label)
        XCTAssertFalse(doxycycline.label.contains("home time"), doxycycline.label)

        app.tab("tab.medications").tap()
        let name = app.staticTexts["Malarone"].firstMatch
        XCTAssertTrue(app.scrollUntilHittable(name))
        name.tap()
        XCTAssertTrue(app.scrollUntilHittable(any(app, labelContains: "waits until at least 20 hours")))
    }
}

/// Screenshots of the travel choices (skipped without `SCREENSHOT_DIR`, like the tour).
final class TravelOptionsScreenshotUITests: XCTestCase {
    private var directory: URL?

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR not set")
        }
        directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
    }

    private func shoot(_ name: String) {
        guard let directory else { return }
        let suffix = ProcessInfo.processInfo.environment["SCREENSHOT_SUFFIX"] ?? ""
        let png = directory.appendingPathComponent("\(name)\(suffix).png")
        let request = directory.appendingPathComponent("\(name)\(suffix).request")
        try? FileManager.default.removeItem(at: png)
        FileManager.default.createFile(atPath: request.path, contents: nil)
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: png.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func option(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    @MainActor
    func testTravelOptionsTour() throws {
        let app = XCUIApplication.launchedForTesting(deviceTimeZone: "America/New_York")
        app.tab("tab.medications").tap()
        app.buttons["button.addMedication"].tap()
        app.segmentedControls["button.addMedicationModeSwitcher"].buttons["Manual"].tap()
        let nameField = app.textFields.matching(identifier: "button.saveMedication.name").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText("Travel Pill\n")   // Return dismisses the keyboard

        let follows = option(app, "Follows me")
        _ = app.scrollUntilHittable(follows, maxSwipes: 14)
        sleep(1)
        shoot("travel-01-section-top")
        _ = app.scrollUntilHittable(option(app, "Count by calendar day"))
        let hours = option(app, "Keep at least 20 hours between doses")
        _ = app.scrollUntilHittable(hours)
        hours.tap()
        let move = option(app, "Move it to the new clock now")
        _ = app.scrollUntilHittable(move)
        move.tap()
        sleep(1)
        shoot("travel-02-choices")
        let example = app.descendants(matching: .any).matching(identifier: "text.travelExample").firstMatch
        _ = app.scrollUntilHittable(example)
        // A short, controlled drag so the whole example is on screen.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        from.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62)))
        sleep(1)
        shoot("travel-03-example")

        app.buttons["button.saveMedication"].tap()
        _ = app.buttons["button.confirmSaveMedication"].waitForExistence(timeout: 5)
        sleep(1)
        shoot("travel-04-save-summary")
        app.buttons["button.confirmSaveMedication"].tap()

        let row = app.staticTexts["Travel Pill"].firstMatch
        _ = row.waitForExistence(timeout: 5)
        row.tap()
        let summary = app.descendants(matching: .any).matching(identifier: "text.scheduleSummary").firstMatch
        _ = app.scrollUntilHittable(summary)
        sleep(1)
        shoot("travel-05-detail-summary")

        app.terminate()
        let away = XCUIApplication.launchedForTesting(seedDemoData: true, twoZones: true, trip: true)
        XCTAssertTrue(away.tab("tab.today").waitForExistence(timeout: 15))
        let malarone = away.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row.scheduledDose.' AND label BEGINSWITH 'Malarone'")).firstMatch
        _ = away.scrollUntilHittable(malarone)
        sleep(1)
        shoot("travel-06-today-away")
        let doxycycline = away.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'row.scheduledDose.' AND label BEGINSWITH 'Doxycycline'")).firstMatch
        _ = away.scrollUntilHittable(doxycycline)
        sleep(1)
        shoot("travel-07-today-away-moved")
    }
}
