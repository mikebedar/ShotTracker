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
            event.minutesLate = dose.minutesLate
            if let medication = dose.medication, medication.isTrackingSupply {
                medication.consumeOneUnit()
            }
        case .skipped:
            dose.completedAt = now
            dose.snoozedUntil = nil
            dose.lastAction = .skipped
            dose.status = .skipped
        case .snoozed:
            let minutes = max(1, dose.medication?.regimens.active?.activeReminderPolicy?.defaultSnoozeMinutes ?? 20)
            // Snoozing again while a snooze is still running extends it from its end, so
            // the offset is always exactly the sum of the snoozes (two taps = twice the
            // delay, never a shorter real delay than the offset claims).
            let base = dose.snoozedUntil.map { max($0, now) } ?? now
            dose.snoozedUntil = base.addingTimeInterval(TimeInterval(minutes * 60))
            dose.snoozeOffsetMinutes = dose.snoozeOffset + minutes
            dose.lastAction = .snoozed
            dose.status = .snoozed
            event.snoozeMinutes = minutes
        case .pending:
            if previousAction == .snoozed {
                // Undoing a snooze takes back exactly that snooze's minutes (and the time
                // it added to a still-running earlier snooze).
                // A snooze logged before offsets were tracked carries no minutes: it added
                // nothing to the offset, so undoing it just ends it.
                if let minutes = lastSnoozeMinutes(of: dose) {
                    dose.snoozeOffsetMinutes = max(0, dose.snoozeOffset - minutes)
                    let earlierEnd = dose.snoozedUntil?.addingTimeInterval(TimeInterval(-minutes * 60))
                    dose.snoozedUntil = earlierEnd.flatMap { $0 > now ? $0 : nil }
                } else {
                    dose.snoozedUntil = nil
                }
            } else {
                // Undoing a take or skip keeps the snoozes that happened before it.
                dose.snoozedUntil = nil
            }
            dose.completedAt = nil
            dose.lastAction = .pending
            dose.status = evaluator.effectiveStatus(for: dose, now: now)
            if previousAction == .taken, let medication = dose.medication, medication.isTrackingSupply {
                medication.restoreOneUnit()
            }
        }
        event.snoozeOffsetMinutes = dose.snoozeOffset

        dose.events.append(event)
        dose.medication?.doseEvents.append(event)
        context.insert(event)
        try context.save()
    }

    /// The minutes the dose's most recent snooze added. Events are unordered in SwiftData,
    /// so "most recent" is the latest `loggedAt`, ties broken by the larger cumulative
    /// offset (each snooze raises it). nil when that snooze predates offset tracking.
    private static func lastSnoozeMinutes(of dose: ScheduledDose) -> Int? {
        let snoozes = dose.events.filter { $0.action == .snoozed }
        let latest = snoozes.max { lhs, rhs in
            lhs.loggedAt == rhs.loggedAt
                ? (lhs.snoozeOffsetMinutes ?? 0) < (rhs.snoozeOffsetMinutes ?? 0)
                : lhs.loggedAt < rhs.loggedAt
        }
        return latest?.snoozeMinutes
    }
}
