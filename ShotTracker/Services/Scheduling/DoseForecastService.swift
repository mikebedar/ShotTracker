import Foundation

/// A dose ready for display, whether backed by a persisted, fully-actionable
/// `ScheduledDose` or computed live via `DoseForecastService` (`isForecasted == true`
/// — read-only, always `.upcoming` since no history can exist for it yet). `medication`
/// is carried alongside the dose rather than read from `dose.medication`, since a
/// forecasted dose's `medication` relationship is intentionally left unset (see below).
struct DisplayDoseItem: Identifiable {
    let dose: ScheduledDose
    let medication: Medication?
    let status: DoseStatus
    let isForecasted: Bool
    var id: String { dose.occurrenceKey }

    /// Wraps a real, persisted dose.
    init(dose: ScheduledDose, status: DoseStatus) {
        self.dose = dose
        self.medication = dose.medication
        self.status = status
        self.isForecasted = false
    }

    fileprivate init(forecastDose: ScheduledDose, medication: Medication) {
        self.dose = forecastDose
        self.medication = medication
        self.status = .upcoming
        self.isForecasted = true
    }
}

/// Read-only occurrences computed live via `DoseScheduleEngine` for dates outside the
/// persisted materialization window (`DoseRepository.materializationLookaheadDays`).
/// These are never inserted into a `ModelContext` — they exist purely to answer "what's
/// scheduled" for calendar browsing and long-range look-ahead, without ever storing rows
/// for occurrences that may be months or years away. They use the same `occurrenceKey`
/// format the real engine call would produce, so nothing conflicts if the persisted
/// window later grows to cover a date that was previously forecasted.
enum DoseForecastService {
    /// Every active medication's occurrences in `range`.
    static func occurrences(
        for medications: [Medication],
        engine: DoseScheduleEngine,
        in range: ClosedRange<Date>,
        preferences: AppPreferences
    ) -> [DisplayDoseItem] {
        medications
            .filter(\.isActive)
            .flatMap { medication in
                transientItems(for: medication, engine: engine, from: range.lowerBound, through: range.upperBound, preferences: preferences)
            }
    }

    /// The earliest forecasted occurrence for a single medication after `date`, searching
    /// up to `limit`. Used as a fallback when a medication's next dose falls beyond the
    /// persisted window (infrequent `.cycle`/`.phased` regimens).
    static func nextOccurrence(
        for medication: Medication,
        engine: DoseScheduleEngine,
        after date: Date,
        limit: Date,
        preferences: AppPreferences
    ) -> DisplayDoseItem? {
        guard date < limit else { return nil }
        return transientItems(for: medication, engine: engine, from: date, through: limit, preferences: preferences)
            .filter { $0.dose.scheduledAt > date }
            .min { $0.dose.scheduledAt < $1.dose.scheduledAt }
    }

    private static func transientItems(
        for medication: Medication,
        engine: DoseScheduleEngine,
        from startDate: Date,
        through endDate: Date,
        preferences: AppPreferences
    ) -> [DisplayDoseItem] {
        guard let regimen = medication.regimens.active else { return [] }

        let inputs = DoseRescheduling.engineInputs(for: medication, regimen: regimen)
        return engine.generateOccurrences(
            for: regimen,
            medicationID: medication.id,
            from: startDate,
            through: endDate,
            preferences: preferences,
            anchorOverride: inputs.anchor,
            rollingInterval: inputs.rollingInterval,
            notBefore: inputs.notBefore
        ).map { occurrence in
            // `medication` is intentionally NOT set on this transient dose: it's never
            // inserted into a ModelContext, but `medication` itself is a real,
            // context-tracked object — wiring the relationship on one side only is
            // undocumented/risky territory for SwiftData's inverse-sync machinery.
            // Threading medication alongside the dose in `DisplayDoseItem` instead keeps
            // this purely read-only with zero chance of touching persisted state.
            let dose = ScheduledDose(
                occurrenceKey: occurrence.occurrenceKey,
                regimenVersion: regimen.version,
                scheduledAt: occurrence.scheduledAt,
                timingLabel: occurrence.timingLabel,
                reminderWindowMinutes: occurrence.reminderWindowMinutes,
                graceWindowMinutes: occurrence.graceWindowMinutes,
                windowEndAt: occurrence.windowEndAt,
                reminderAt: occurrence.reminderAt
            )
            return DisplayDoseItem(forecastDose: dose, medication: medication)
        }
    }
}
