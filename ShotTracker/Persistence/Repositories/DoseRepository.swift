import Foundation
import SwiftData

@MainActor
enum DoseRepository {
    /// Rolling window of persisted, actionable `ScheduledDose` rows. Anything outside this
    /// range is served live via `DoseForecastService` instead of being materialized —
    /// storage never grows to cover "forever," only the window doses can actually be
    /// taken/skipped/snoozed in.
    nonisolated static let materializationLookbackDays = 7
    nonisolated static let materializationLookaheadDays = 90

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
                notBefore: inputs.notBefore,
                rollingAnchorSlot: inputs.rollingAnchorSlot
            )

            var regimenCalendar = Calendar(identifier: .gregorian)
            regimenCalendar.timeZone = TimeZone(identifier: regimen.timeZoneIdentifier) ?? .current
            let plan = DoseReconciliation.plan(
                existing: medication.scheduledDoses.map(DoseReconciliation.Row.init),
                generated: generated,
                currentVersion: regimen.version,
                rangeStart: regimenCalendar.startOfDay(for: start),
                rangeEnd: end,
                now: referenceDate,
                calendar: regimenCalendar
            )

            let doseByID = Dictionary(uniqueKeysWithValues: medication.scheduledDoses.map { ($0.id, $0) })
            for (doseID, occurrence) in plan.updates {
                guard let existing = doseByID[doseID] else { continue }
                existing.occurrenceKey = occurrence.occurrenceKey
                existing.scheduledAt = occurrence.scheduledAt
                existing.timingLabel = occurrence.timingLabel
                existing.reminderWindowMinutes = occurrence.reminderWindowMinutes
                existing.graceWindowMinutes = occurrence.graceWindowMinutes
                existing.windowEndAt = occurrence.windowEndAt
                existing.reminderAt = occurrence.reminderAt
                existing.regimenVersion = regimen.version
                existing.timingID = occurrence.timingID
            }

            for occurrence in plan.inserts {
                let dose = ScheduledDose(
                    occurrenceKey: occurrence.occurrenceKey,
                    regimenVersion: regimen.version,
                    scheduledAt: occurrence.scheduledAt,
                    timingLabel: occurrence.timingLabel,
                    reminderWindowMinutes: occurrence.reminderWindowMinutes,
                    graceWindowMinutes: occurrence.graceWindowMinutes,
                    windowEndAt: occurrence.windowEndAt,
                    reminderAt: occurrence.reminderAt,
                    medication: medication,
                    generatedAt: referenceDate,
                    timingID: occurrence.timingID
                )
                medication.scheduledDoses.append(dose)
                context.insert(dose)
            }

            for doseID in plan.deletes {
                if let dose = doseByID[doseID] {
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
        // Snoozing a dose whose window hasn't opened would pull it *forward* (the snooze
        // end becomes its new window start). Nothing to snooze yet — and no event.
        if action == .snoozed, evaluator.effectiveStatus(for: dose, now: now) == .upcoming {
            return
        }
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
