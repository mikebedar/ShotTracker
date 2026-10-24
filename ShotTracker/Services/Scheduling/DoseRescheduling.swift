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
        /// For a rolling regimen: the slot the last real dose filled on the anchor day,
        /// so that day's later slots are still generated.
        var rollingAnchorSlot: RollingAnchorSlot? = nil
        /// Fixed policies: nothing on days before this instant's day (the regimen
        /// version's creation), read on each occurrence's own clock — see
        /// `fixedGenerationFloor`.
        var floorDay: Date? = nil
    }

    /// The latest taken dose, as plain values (what rolling generation counts from).
    struct LastTakenDose: Hashable {
        let completedAt: Date
        let timingID: UUID?
        let timingLabel: String
    }

    static func engineInputs(for medication: Medication, regimen: MedicationRegimen) -> EngineInputs {
        let last = medication.lastTakenDose.flatMap { dose in
            dose.completedAt.map { LastTakenDose(completedAt: $0, timingID: dose.timingID, timingLabel: dose.timingLabel) }
        }
        return engineInputs(regimen: regimen, lastTaken: last)
    }

    /// `engineInputs(for:regimen:)` on plain values (the travel example's simulated trip).
    static func engineInputs(regimen: MedicationRegimen, lastTaken lastDose: LastTakenDose?) -> EngineInputs {
        let calendar = Self.calendar(for: regimen)

        // Only `.rescheduleFromLastDose`, on a frequency with a single nominal interval,
        // after at least one real dose, rolls. Everything else keeps fixed behavior
        // (anchor = the regimen's own anchorDate), floored to the version's creation.
        guard
            regimen.missedDosePolicy == .rescheduleFromLastDose,
            let interval = regimen.nominalIntervalComponents,
            let lastDose
        else {
            return EngineInputs(
                anchor: regimen.anchorDate,
                notBefore: nil,
                rollingInterval: nil,
                floorDay: fixedGenerationFloor(for: regimen)
            )
        }

        let lastTaken = lastDose.completedAt
        return EngineInputs(
            anchor: calendar.startOfDay(for: lastTaken),
            notBefore: lastTaken,
            rollingInterval: interval,
            rollingAnchorSlot: RollingAnchorSlot(timingID: lastDose.timingID, timingLabel: lastDose.timingLabel)
        )
    }

    /// Fixed-policy generation floor: a regimen version must never materialize
    /// occurrences from before it existed — editing a schedule bumps the version, and
    /// regenerating the materialization window's 7-day lookback under the new version's
    /// keys would otherwise fabricate a week of phantom "overdue" doses for days that
    /// already happened. Slots on the creation day that the old version already handled
    /// (the "took today's dose, then edited the schedule" flow) are reconciled by
    /// `DoseRepository.refreshSchedules`, slot by slot, so a twice-daily med keeps its
    /// evening dose after an edit made once the morning one was taken.
    ///
    /// The floor is a fixed day (the version's creation day), so it becomes inert once the
    /// rolling window advances past it — it never suppresses or prunes rows generated
    /// later under this same version. The engine reads the day on each occurrence's own
    /// clock (`floorDay`): as an instant on the home clock it fell in the local afternoon
    /// in Tokyo, so a version created there (an edit while travelling) dropped that
    /// morning's slot that follows the device, and the old version's still-open row was
    /// pruned with it.
    private static func fixedGenerationFloor(for regimen: MedicationRegimen) -> Date {
        regimen.createdAt
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
