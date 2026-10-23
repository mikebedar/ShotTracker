import Foundation
import SwiftData

@MainActor
enum DoseRepository {
    /// Rolling window of persisted, actionable `ScheduledDose` rows. Anything outside this
    /// range is served live via `DoseForecastService` instead of being materialized —
    /// storage never grows to cover "forever," only the window doses can actually be
    /// taken/skipped/snoozed in.
    static let materializationLookbackDays = 7
    static let materializationLookaheadDays = 90

    static func refreshSchedules(
        in context: ModelContext,
        engine: DoseScheduleEngine,
        preferences: AppPreferences,
        referenceDate: Date = .now,
        horizonDays: Int = materializationLookaheadDays
    ) throws {
        let medications = try MedicationRepository.fetchMedications(in: context)
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(byAdding: .day, value: -materializationLookbackDays, to: referenceDate) ?? referenceDate
        let end = calendar.date(byAdding: .day, value: horizonDays, to: referenceDate) ?? referenceDate

        for medication in medications where medication.isActive {
            guard let regimen = MedicationRepository.currentRegimen(for: medication) else { continue }

            let inputs = DoseRescheduling.engineInputs(for: medication, regimen: regimen)
            let generated = engine.generateOccurrences(
                for: regimen,
                medicationID: medication.id,
                from: start,
                through: end,
                preferences: preferences,
                anchorOverride: inputs.anchor,
                rollingInterval: inputs.rollingInterval,
                notBefore: inputs.notBefore
            )

            let existingByKey = Dictionary(uniqueKeysWithValues: medication.scheduledDoses.map { ($0.occurrenceKey, $0) })
            let validKeys = Set(generated.map(\.occurrenceKey))

            for occurrence in generated {
                if let existing = existingByKey[occurrence.occurrenceKey] {
                    existing.scheduledAt = occurrence.scheduledAt
                    existing.timingLabel = occurrence.timingLabel
                    existing.reminderWindowMinutes = occurrence.reminderWindowMinutes
                    existing.graceWindowMinutes = occurrence.graceWindowMinutes
                    existing.windowEndAt = occurrence.windowEndAt
                    existing.reminderAt = occurrence.reminderAt
                    existing.regimenVersion = regimen.version
                } else {
                    let dose = ScheduledDose(
                        occurrenceKey: occurrence.occurrenceKey,
                        regimenVersion: regimen.version,
                        scheduledAt: occurrence.scheduledAt,
                        timingLabel: occurrence.timingLabel,
                        reminderWindowMinutes: occurrence.reminderWindowMinutes,
                        graceWindowMinutes: occurrence.graceWindowMinutes,
                        windowEndAt: occurrence.windowEndAt,
                        reminderAt: occurrence.reminderAt,
                        medication: medication
                    )
                    medication.scheduledDoses.append(dose)
                    context.insert(dose)
                }
            }

            for dose in medication.scheduledDoses where !validKeys.contains(dose.occurrenceKey) {
                if dose.events.isEmpty, dose.completedAt == nil {
                    context.delete(dose)
                }
            }
        }

        try context.save()
    }

    static func applyAction(
        _ action: DoseActionType,
        to dose: ScheduledDose,
        note: String = "",
        now: Date = .now,
        context: ModelContext
    ) throws {
        let evaluator = DoseStatusEvaluator()
        let previousAction = dose.lastAction
        let event = DoseEvent(
            loggedAt: now,
            action: action,
            note: note,
            medication: dose.medication,
            scheduledDose: dose
        )

        switch action {
        case .taken:
            dose.completedAt = now
            dose.snoozedUntil = nil
            dose.lastAction = .taken
            dose.status = evaluator.completionStatus(for: dose, completionDate: now)
            if let medication = dose.medication, medication.isTrackingSupply {
                medication.consumeOneUnit()
            }
        case .skipped:
            dose.completedAt = now
            dose.snoozedUntil = nil
            dose.lastAction = .skipped
            dose.status = .skipped
        case .snoozed:
            let minutes = dose.medication?.regimens.active?.activeReminderPolicy?.defaultSnoozeMinutes ?? 20
            dose.snoozedUntil = now.addingTimeInterval(TimeInterval(minutes * 60))
            dose.lastAction = .snoozed
            dose.status = .snoozed
        case .pending:
            dose.completedAt = nil
            dose.snoozedUntil = nil
            dose.lastAction = .pending
            dose.status = evaluator.effectiveStatus(for: dose, now: now)
            if previousAction == .taken, let medication = dose.medication, medication.isTrackingSupply {
                medication.restoreOneUnit()
            }
        }

        dose.events.append(event)
        dose.medication?.doseEvents.append(event)
        context.insert(event)
        try context.save()
    }
}
