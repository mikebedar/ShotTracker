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
    static let medicationLookupResultRow = "row.medicationLookupResult"
    static let medicationLookupVariantRow = "row.medicationLookupVariant"
    static let searchField = "field.medicationSearch"
    static let saveMedicationButton = "button.saveMedication"
    static let takeDoseButton = "button.takeDose"
    static let snoozeDoseButton = "button.snoozeDose"
    static let skipDoseButton = "button.skipDose"
    static let notificationToggle = "toggle.notifications"
    static let syncToggle = "toggle.icloudSync"

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

    static func skipDoseButton(_ id: UUID) -> String {
        "button.skipDose.\(id.uuidString)"
    }

    static func deleteMedicationButton(_ id: UUID) -> String {
        "button.deleteMedication.\(id.uuidString)"
    }
}
