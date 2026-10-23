import XCTest

extension XCUIApplication {
    /// A fresh, deterministic launch: in-memory store, throwaway preferences (so Today
    /// starts in list mode), stubbed RxTerms/openFDA, and optionally the demo data set.
    static func launchedForTesting(seedDemoData: Bool = false) -> XCUIApplication {
        // A previous run can leave the simulator in landscape, where the tab bar isn't a
        // tab bar any more.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestStubNetwork"]
        if seedDemoData {
            app.launchArguments.append("-seedDemoData")
        }
        app.launch()
        return app
    }

    /// The tab bar button for one of the `tab.*` identifiers. The system tab bar's buttons
    /// can't carry app identifiers (they report their SF Symbol name), so this maps the
    /// identifier to the tab's title.
    func tab(_ identifier: String) -> XCUIElement {
        let titles = ["tab.today": "Today", "tab.medications": "Medications", "tab.history": "History", "tab.settings": "Settings"]
        return tabBars.buttons[titles[identifier] ?? identifier]
    }

    /// Adds a daily medication in Manual mode and returns to the Medications list.
    func addManualMedication(named name: String) {
        tab("tab.medications").tap()
        buttons["button.addMedication"].tap()
        segmentedControls["button.addMedicationModeSwitcher"].buttons["Manual"].tap()
        let nameField = textFields.matching(identifier: "button.saveMedication.name").firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        nameField.tap()
        nameField.typeText(name)
        buttons["button.saveMedication"].tap()
    }

    func scrollUntilHittable(_ element: XCUIElement, maxSwipes: Int = 10) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            // Slow swipes: a fast one flings a Form past rows it never builds.
            swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }
}
