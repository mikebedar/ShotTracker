import XCTest

/// Walks every screen over the demo data and writes one PNG per screen to the folder in
/// `TEST_RUNNER_SCREENSHOT_DIR` (set it in the environment of `xcodebuild test`). Skipped
/// when the variable isn't set, so the normal suite never writes files.
final class ScreenshotTourUITests: XCTestCase {
    private var directory: URL?

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("SCREENSHOT_DIR not set")
        }
        directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
    }

    /// XCUITest's own screenshots come back rotated and cropped on the iOS 27 simulator,
    /// so the host takes them: the test drops a request file and waits for the PNG that
    /// a `simctl io … screenshot` loop on the Mac writes in reply.
    private func shoot(_ app: XCUIApplication, _ name: String) {
        guard let directory else { return }
        let png = directory.appendingPathComponent("\(name).png")
        let request = directory.appendingPathComponent("\(name).request")
        try? FileManager.default.removeItem(at: png)
        FileManager.default.createFile(atPath: request.path, contents: nil)
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: png.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    @MainActor
    func testTour() throws {
        let app = XCUIApplication.launchedForTesting(seedDemoData: true)
        let suffix = ProcessInfo.processInfo.environment["SCREENSHOT_SUFFIX"] ?? ""
        func shot(_ name: String) { shoot(app, name + suffix) }

        XCTAssertTrue(app.tab("tab.today").waitForExistence(timeout: 15))
        sleep(1)
        shot("01-today-top")
        app.swipeUp()
        shot("02-today-middle")
        app.swipeUp()
        app.swipeUp()
        shot("03-today-bottom")

        app.segmentedControls["button.todayViewModeSwitcher"].buttons["Calendar"].tap()
        sleep(1)
        shot("04-today-calendar")
        app.segmentedControls["button.todayViewModeSwitcher"].buttons["List"].tap()

        app.tab("tab.medications").tap()
        sleep(1)
        shot("05-medications")
        app.staticTexts["Metformin"].firstMatch.tap()
        sleep(1)
        shot("06-medication-detail")
        app.staticTexts["Scheduled doses"].firstMatch.tap()
        sleep(1)
        shot("07-scheduled-doses")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.staticTexts["History"].firstMatch.tap()
        sleep(1)
        shot("08-medication-history")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Edit"].tap()
        sleep(1)
        shot("09-edit-top")
        app.swipeUp()
        shot("10-edit-schedule")
        app.swipeUp()
        app.swipeUp()
        shot("11-edit-reminders")
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.staticTexts["Prednisone"].firstMatch.tap()
        sleep(1)
        shot("12-phased-detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["button.addMedication"].tap()
        sleep(1)
        let search = app.textFields["field.medicationSearch"]
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("furosemide")
            _ = app.buttons.matching(identifier: "row.medicationLookupResult").firstMatch.waitForExistence(timeout: 5)
            shot("13-add-lookup")
        }
        app.buttons["Cancel"].tap()

        app.tab("tab.history").tap()
        sleep(1)
        shot("14-history")

        app.tab("tab.settings").tap()
        sleep(1)
        shot("15-settings")
        app.swipeUp()
        shot("16-settings-bottom")
    }
}
