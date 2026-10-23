import Foundation

/// Pure policy logic that decides how a medication's `MissedDosePolicy` translates into
/// scheduling-engine inputs, plus the minimum-interval safety check. Shared by both the
/// materialized tier (`DoseRepository.refreshSchedules`) and the forecast tier
/// (`DoseForecastService`) so their projections always agree.
enum DoseRescheduling {
    /// What to feed `DoseScheduleEngine.generateOccurrences` for a given medication/regimen.
    struct EngineInputs {
        let anchor: Date
        let notBefore: Date?
        let rollingInterval: DateComponents?
    }

    static func engineInputs(for medication: Medication, regimen: MedicationRegimen) -> EngineInputs {
        let calendar = Self.calendar(for: regimen)

        // Only `.rescheduleFromLastDose`, on a frequency with a single nominal interval,
        // after at least one real dose, rolls. Everything else keeps fixed behavior
        // (anchor = the regimen's own anchorDate), floored to the version's creation.
        guard
            regimen.missedDosePolicy == .rescheduleFromLastDose,
            let interval = regimen.nominalIntervalComponents,
            let lastTaken = medication.lastAdministeredAt
        else {
            return EngineInputs(
                anchor: regimen.anchorDate,
                notBefore: fixedGenerationFloor(for: medication, regimen: regimen, calendar: calendar),
                rollingInterval: nil
            )
        }

        return EngineInputs(
            anchor: calendar.startOfDay(for: lastTaken),
            notBefore: lastTaken,
            rollingInterval: interval
        )
    }

    /// Fixed-policy generation floor: a regimen version must never materialize
    /// occurrences from before it existed — editing a schedule bumps the version, and
    /// regenerating the materialization window's 7-day lookback under the new version's
    /// keys would otherwise fabricate a week of phantom "overdue" doses for days that
    /// already happened. And if a dose was already completed on the day the version was
    /// created (the common "took today's dose, then edited the schedule" flow), the new
    /// grid starts the *next* day — today was already handled.
    ///
    /// The floor is a fixed instant (the version's creation day), so it becomes inert
    /// once the rolling window advances past it — it never suppresses or prunes rows
    /// generated later under this same version.
    private static func fixedGenerationFloor(
        for medication: Medication,
        regimen: MedicationRegimen,
        calendar: Calendar
    ) -> Date {
        var floorDay = calendar.startOfDay(for: regimen.createdAt)

        let completedOnCreationDay = medication.scheduledDoses.contains { dose in
            guard let completedAt = dose.completedAt else { return false }
            return calendar.isDate(completedAt, inSameDayAs: regimen.createdAt)
        }
        if completedOnCreationDay, let nextDay = calendar.date(byAdding: .day, value: 1, to: floorDay) {
            floorDay = nextDay
        }

        // Exclusive filter (`scheduledAt <= notBefore` is dropped): back off one second
        // so a dose scheduled exactly at the floor's midnight still survives.
        return floorDay.addingTimeInterval(-1)
    }

    struct MinIntervalWarning: Equatable {
        let lastTaken: Date
        let minimumHours: Int
        let hoursSinceLastDose: Int

        var message: String {
            let daysSince = max(1, Int((Double(hoursSinceLastDose) / 24).rounded()))
            let minDays = max(1, Int((Double(minimumHours) / 24).rounded()))
            let sinceText = daysSince == 1 ? "1 day" : "\(daysSince) days"
            let minText = minDays == 1 ? "1 day" : "\(minDays) days"
            return "You last took this \(sinceText) ago — sooner than the recommended \(minText) between doses. Take it anyway?"
        }
    }

    /// Non-nil only for `.rescheduleFromLastDose` when taking a dose now would fall inside
    /// the medication's minimum interval since its last actual dose.
    static func minimumIntervalWarning(
        for medication: Medication,
        regimen: MedicationRegimen,
        takingAt now: Date = .now
    ) -> MinIntervalWarning? {
        guard regimen.missedDosePolicy == .rescheduleFromLastDose,
              let lastTaken = medication.lastAdministeredAt,
              lastTaken <= now
        else {
            return nil
        }

        let minimumHours = regimen.effectiveMinimumIntervalHours
        let elapsedHours = now.timeIntervalSince(lastTaken) / 3600
        guard elapsedHours < Double(minimumHours) else { return nil }

        return MinIntervalWarning(
            lastTaken: lastTaken,
            minimumHours: minimumHours,
            hoursSinceLastDose: Int(elapsedHours.rounded(.down))
        )
    }

    private static func calendar(for regimen: MedicationRegimen) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: regimen.timeZoneIdentifier) ?? .current
        return calendar
    }
}
