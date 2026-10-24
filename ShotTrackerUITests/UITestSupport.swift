import XCTest

extension XCUIApplication {
    /// A fresh, deterministic launch: in-memory store, throwaway preferences (so Today
    /// starts in list mode), stubbed RxTerms/openFDA, and optionally the demo data set.
    /// `twoZones` runs the device in Paris over demo schedules written in New York
    /// (`-deviceTimeZone`, `-demoHomeTimeZone`), for the "home · here" display.
    /// `trip` (with `twoZones`): the demo is planned on its home clocks as if the phone had
    /// just landed, with two medications on non-default travel options (`-demoTrip`).
    /// `deviceTimeZone` alone pins the device's zone (a deterministic home for new meds).
    static func launchedForTesting(seedDemoData: Bool = false, twoZones: Bool = false, trip: Bool = false, deviceTimeZone: String? = nil) -> XCUIApplication {
        // A previous run can leave the simulator in landscape, where the tab bar isn't a
        // tab bar any more.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestStubNetwork"]
        if seedDemoData {
            app.launchArguments.append("-seedDemoData")
        }
        if twoZones {
            app.launchArguments += ["-deviceTimeZone", "Europe/Paris", "-demoHomeTimeZone", "America/New_York"]
            if trip { app.launchArguments.append("-demoTrip") }
        } else if let deviceTimeZone {
            app.launchArguments += ["-deviceTimeZone", deviceTimeZone]
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
        saveMedication()
    }

    /// Taps Save in the edit form and, when the schedule is new or changed, Save again in
    /// the "How this schedule works" confirmation.
    func saveMedication() {
        buttons["button.saveMedication"].tap()
        let confirm = buttons["button.confirmSaveMedication"]
        if confirm.waitForExistence(timeout: 5) {
            confirm.tap()
        }
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
