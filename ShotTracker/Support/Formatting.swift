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

    static func scheduleText(for regimen: MedicationRegimen) -> String {
        let timingSummary = regimen.timings.map(\.title).joined(separator: ", ")

        switch regimen.recurrenceRule.frequency {
        case .daily:
            return "Daily at \(timingSummary)"
        case .intervalDays:
            return "Every \(regimen.recurrenceRule.intervalDays) days at \(timingSummary)"
        case .weekly:
            // No weekdays means "the start date's weekday" (what the engine does).
            let weekdays = regimen.recurrenceRule.weekdays.isEmpty
                ? [Calendar.current.component(.weekday, from: regimen.anchorDate)]
                : regimen.recurrenceRule.weekdays
            let days = weekdays.map(weekdayTitle).joined(separator: ", ")
            return "Weekly on \(days) at \(timingSummary)"
        case .monthly:
            return "Monthly on day \(regimen.recurrenceRule.dayOfMonth) at \(timingSummary)"
        case .cycle:
            return "\(regimen.recurrenceRule.cycleOnDays) days on, \(regimen.recurrenceRule.cycleOffDays) days off at \(timingSummary)"
        case .phased:
            let phases = regimen.phases.sorted { $0.startDayOffset < $1.startDayOffset }
            guard !phases.isEmpty else { return "Phased schedule at \(timingSummary)" }
            let steps = phases.map { phase -> String in
                let cadence = phase.recurrenceRule.frequency == .intervalDays
                    ? "every \(phase.recurrenceRule.intervalDays) days"
                    : "daily"
                let length = phase.durationDays.map { "\($0) day\($0 == 1 ? "" : "s")" } ?? "ongoing"
                return "\(phase.title): \(cadence), \(length)"
            }
            return steps.joined(separator: " → ") + " at \(timingSummary)"
        }
    }

    nonisolated static func weekdayTitle(_ index: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard (1...symbols.count).contains(index) else { return "Day \(index)" }
        return symbols[index - 1]
    }
}
