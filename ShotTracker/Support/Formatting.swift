import Foundation

enum AppFormatting {
    nonisolated static func medicationSubtitle(for medication: Medication) -> String? {
        guard
            let canonicalName = medication.canonicalName,
            !canonicalName.isEmpty,
            canonicalName != medication.displayName
        else {
            return nil
        }

        return canonicalName
    }

    nonisolated static func relativeDueText(for date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    nonisolated static func scheduleText(for regimen: MedicationRegimen) -> String {
        let timingSummary = regimen.timings.map(\.title).joined(separator: ", ")

        switch regimen.recurrenceRule.frequency {
        case .daily:
            return "Daily at \(timingSummary)"
        case .intervalDays:
            return "Every \(regimen.recurrenceRule.intervalDays) days at \(timingSummary)"
        case .weekly:
            let days = regimen.recurrenceRule.weekdays.map(weekdayTitle).joined(separator: ", ")
            return "Weekly on \(days) at \(timingSummary)"
        case .monthly:
            return "Monthly on day \(regimen.recurrenceRule.dayOfMonth) at \(timingSummary)"
        case .cycle:
            return "\(regimen.recurrenceRule.cycleOnDays) days on, \(regimen.recurrenceRule.cycleOffDays) days off at \(timingSummary)"
        case .phased:
            return "Phased schedule"
        }
    }

    nonisolated static func weekdayTitle(_ index: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard (1...symbols.count).contains(index) else { return "Day \(index)" }
        return symbols[index - 1]
    }
}
