import Foundation

enum AccessibilityID {
    static let todayTab = "tab.today"
    static let medicationsTab = "tab.medications"
    static let historyTab = "tab.history"
    static let settingsTab = "tab.settings"
    static let todayViewModeSwitcher = "button.todayViewModeSwitcher"
    static let todayCalendarView = "view.todayCalendar"
    static let addMedicationButton = "button.addMedication"
    static let addMedicationModeSwitcher = "button.addMedicationModeSwitcher"
    static let deleteMedicationButton = "button.deleteMedication"
    static let refillQuantityField = "field.refillQuantity"
    static let medicationLookupResultRow = "row.medicationLookupResult"
    static let medicationLookupVariantRow = "row.medicationLookupVariant"
    static let searchField = "field.medicationSearch"
    static let saveMedicationButton = "button.saveMedication"
    static let takeDoseButton = "button.takeDose"
    static let snoozeDoseButton = "button.snoozeDose"
    static let skipDoseButton = "button.skipDose"
    static let notificationToggle = "toggle.notifications"
    static let homeTimeZoneRow = "row.homeTimeZone"
    static let homeTimeZoneNote = "text.homeTimeZoneNote"
    static let travelPolicyPicker = "picker.travelPolicy"
    static let travelSpacingPicker = "picker.travelSpacing"
    static let travelHoursStepper = "stepper.travelHours"
    static let travelLandingPicker = "picker.travelLanding"
    static let travelDestinationRow = "row.travelDestination"
    static let travelExample = "text.travelExample"
    static let confirmSaveMedicationButton = "button.confirmSaveMedication"
    static let keepEditingButton = "button.keepEditing"
    static let scheduleSummary = "text.scheduleSummary"
    static let heldDoseNote = "text.heldDose"

    static func medicationRow(_ id: UUID) -> String {
        "row.medication.\(id.uuidString)"
    }

    static func scheduledDoseRow(_ id: UUID) -> String {
        "row.scheduledDose.\(id.uuidString)"
    }

    static func takeDoseButton(_ id: UUID) -> String {
        "button.takeDose.\(id.uuidString)"
    }

    static func snoozeDoseButton(_ id: UUID) -> String {
        "button.snoozeDose.\(id.uuidString)"
    }

    static func undoDoseButton(_ id: UUID) -> String {
        "button.undoDose.\(id.uuidString)"
    }

    static func skipDoseButton(_ id: UUID) -> String {
        "button.skipDose.\(id.uuidString)"
    }

    static func deleteMedicationButton(_ id: UUID) -> String {
        "button.deleteMedication.\(id.uuidString)"
    }

    /// The swipe actions on a Today card (`RowAction`s; not "button.…" so tests that find the first
    /// "button.takeDose." never pick a swipe button).
    static func swipeTakeDose(_ id: UUID) -> String {
        "swipe.takeDose.\(id.uuidString)"
    }

    static func swipeSkipDose(_ id: UUID) -> String {
        "swipe.skipDose.\(id.uuidString)"
    }
}
