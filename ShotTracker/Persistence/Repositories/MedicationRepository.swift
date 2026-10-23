import Foundation
import SwiftData

@MainActor
enum MedicationRepository {
    static func fetchMedications(in context: ModelContext) throws -> [Medication] {
        var descriptor = FetchDescriptor<Medication>(sortBy: [SortDescriptor(\.displayName)])
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor)
    }

    static func currentRegimen(for medication: Medication) -> MedicationRegimen? {
        medication.regimens.active
    }

    /// "Deletes" a medication without losing its history. Marks it inactive — hidden from
    /// the medications list, Today, and Coming Up, and skipped entirely by
    /// `DoseRepository.refreshSchedules`'s generation loop — then prunes only its
    /// *unresolved* scheduled doses (upcoming/due/overdue/snoozed). Once a medication goes
    /// inactive, `refreshSchedules` never touches its rows again (its per-medication prune
    /// loop is gated on `isActive` too), so any left-over future doses would otherwise sit
    /// around — and keep firing notifications — forever. Taken/skipped doses, `DoseEvent`s,
    /// and `RefillEvent`s are left untouched: that's the actual history this preserves.
    /// Callers are responsible for calling `AppDependencies.refreshSchedules(context:)`
    /// afterward so any now-stale local notifications get cleared.
    static func archive(_ medication: Medication, in context: ModelContext) throws {
        medication.isActive = false

        let resolvedStatuses: Set<DoseStatus> = [.takenOnTime, .takenLate, .skipped]
        for dose in medication.scheduledDoses where !resolvedStatuses.contains(dose.status) {
            // `ScheduledDose.events` cascades, so a snoozed or undone dose would take its
            // logged events with it. Detach them first: they stay in History (linked to
            // the medication), just without the scheduled-dose context.
            for event in dose.events {
                event.scheduledDose = nil
            }
            dose.events.removeAll()
            context.delete(dose)
        }

        try context.save()
    }

    /// Reverses an archive: the medication rejoins the active list and dose generation.
    /// Callers must call `AppDependencies.refreshSchedules(context:)` afterward so its
    /// occurrences (pruned at archive time) get rebuilt and notifications rescheduled.
    static func unarchive(_ medication: Medication, in context: ModelContext) throws {
        medication.isActive = true
        try context.save()
    }

    /// Record a refill: add `quantity` units as a new container and log a `RefillEvent`.
    static func logRefill(
        _ quantity: Int,
        for medication: Medication,
        note: String = "",
        now: Date = .now,
        in context: ModelContext
    ) throws {
        guard quantity > 0 else { return }
        medication.addRefill(quantity: quantity, at: now)
        let event = RefillEvent(loggedAt: now, quantity: quantity, note: note, medication: medication)
        medication.refillEvents.append(event)
        context.insert(event)
        try context.save()
    }
}
