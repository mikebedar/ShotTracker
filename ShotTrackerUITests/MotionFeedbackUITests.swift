import XCTest

/// Actual dose actions over the app's in-memory demo store. Every case starts with fresh data and preferences.
final class MotionFeedbackUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(motion: String = "system", extra: [String] = []) -> XCUIApplication {
        XCUIApplication.launchedForTesting(seedDemoData: true, arguments: ["-atelierMotion", motion] + extra)
    }

    /// Returns the exact dose identity before it moves from an actionable section into Done.
    @MainActor private func takeFirst(_ app: XCUIApplication) -> String {
        let take = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'button.takeDose.'")).firstMatch
        XCTAssertTrue(take.waitForExistence(timeout: 15))
        XCTAssertTrue(app.scrollUntilHittable(take))
        let id = String(take.identifier.dropFirst("button.takeDose.".count))
        take.tap()
        XCTAssertTrue(app.otherElements["toast"].firstMatch.waitForExistence(timeout: 5))
        return id
    }

    @MainActor private func assertTakeRestored(_ id: String, in app: XCUIApplication) {
        let take = app.buttons["button.takeDose.\(id)"]
        for _ in 0..<8 where !take.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(take.waitForExistence(timeout: 5), "Undo restored dose \(id)")
    }

    @MainActor private func assertStillTaken(_ id: String, in app: XCUIApplication) {
        let undo = app.buttons["button.undoDose.\(id)"]
        XCTAssertTrue(app.scrollUntilHittable(undo), "The earlier dose stays completed")
        XCTAssertFalse(app.buttons["button.takeDose.\(id)"].exists, "The earlier action must not be undone")
    }

    @MainActor private func assertClearsTabBar(_ app: XCUIApplication) {
        let toast = app.otherElements["toast"].firstMatch
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.exists)
        XCTAssertLessThanOrEqual(toast.frame.maxY, tabBar.frame.minY + 1,
                                 "Toast \(toast.frame) overlaps tab bar \(tabBar.frame)")
        XCTAssertGreaterThanOrEqual(app.buttons["toast.action"].frame.height, 44)
    }

    @MainActor func testUndismissedDragKeepsUndoWorkingInEveryMotionMode() {
        for motion in ["system", "reduced", "off"] {
            let app = launch(motion: motion)
            let id = takeFirst(app)
            assertClearsTabBar(app)
            let toast = app.otherElements["toast"].firstMatch
            let resting = toast.frame
            let start = toast.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -60)))
            XCTAssertTrue(toast.exists, "A drag away from the dismissal edge keeps the toast")
            XCTAssertEqual(toast.frame.midY, resting.midY, accuracy: 2)
            app.buttons["toast.action"].tap()
            assertTakeRestored(id, in: app)
            app.terminate()
        }
    }

    @MainActor func testSwipeDismissalDoesNotUndoAndNextToastWorks() {
        for motion in ["system", "reduced", "off"] {
            let app = launch(motion: motion)
            let first = takeFirst(app)
            let toast = app.otherElements["toast"].firstMatch
            toast.swipeDown()
            XCTAssertTrue(toast.waitForNonExistence(timeout: 3))
            let second = takeFirst(app)
            XCTAssertNotEqual(first, second)
            assertClearsTabBar(app)
            app.buttons["toast.action"].tap()
            assertTakeRestored(second, in: app)
            assertStillTaken(first, in: app)
            app.terminate()
        }
    }

    @MainActor func testSuccessiveTakesUndoOnlyTheLatestDose() {
        for motion in ["system", "reduced", "off"] {
            let app = launch(motion: motion)
            let first = takeFirst(app)
            let second = takeFirst(app)
            XCTAssertNotEqual(first, second)
            XCTAssertEqual(app.buttons.matching(identifier: "toast.action").count, 1)
            app.buttons["toast.action"].tap()
            assertTakeRestored(second, in: app)
            assertStillTaken(first, in: app)
            app.terminate()
        }
    }

    @MainActor func testToastAppearanceMatrix() {
        for theme in ["system", "warm"] {
            for scheme in ["light", "dark"] {
                let app = launch(extra: ["-atelierTheme", theme, "-atelierAppearance", scheme, "-uiTestHoldToast"])
                let id = takeFirst(app)
                assertClearsTabBar(app)
                capture("shottracker-toast-\(theme)-\(scheme)")
                app.buttons["toast.action"].tap()
                assertTakeRestored(id, in: app)
                app.terminate()
            }
        }
    }

    /// Optional host captures: iOS 27's XCUITest screenshots can be rotated/cropped; use the existing tour protocol.
    private func capture(_ name: String) {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path)
        let png = directory.appendingPathComponent(name + ".png")
        let request = directory.appendingPathComponent(name + ".request")
        try? FileManager.default.removeItem(at: png)
        XCTAssertTrue(FileManager.default.createFile(atPath: request.path, contents: nil))
        let captured = NSPredicate { _, _ in FileManager.default.fileExists(atPath: png.path) }
        let ready = XCTNSPredicateExpectation(predicate: captured, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed, "Host did not capture \(name)")
    }
}
