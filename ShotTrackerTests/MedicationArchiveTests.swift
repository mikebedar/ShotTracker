import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// Exercises `MedicationRepository.archive` against a real (in-memory) SwiftData store —
/// unlike the app's other repository tests, this one needs actual persistence semantics
/// (`context.delete`, cascade relationships) to verify correctly, not just unmanaged model
/// instances.
@MainActor
struct MedicationArchiveTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Medication.self, MedicationRegimen.self, RegimenPhase.self,
            ReminderPolicy.self, ScheduledDose.self, DoseEvent.self, RefillEvent.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        return ModelContext(container)
    }

    private func dose(status: DoseStatus, scheduledAt: Date = .now) -> ScheduledDose {
        ScheduledDose(
            occurrenceKey: UUID().uuidString,
            regimenVersion: 1,
            scheduledAt: scheduledAt,
            timingLabel: "morning",
            reminderWindowMinutes: 60,
            graceWindowMinutes: 120,
            status: status
        )
    }

    @Test func archiveMarksInactiveAndPrunesOnlyUnresolvedDoses() throws {
        let context = try makeContext()
        let medication = Medication(displayName: "Test Med")
        context.insert(medication)

        let takenDose = dose(status: .takenOnTime)
        let takenLateDose = dose(status: .takenLate)
        let skippedDose = dose(status: .skipped)
        let upcomingDose = dose(status: .upcoming)
        let dueDose = dose(status: .due)
        let overdueDose = dose(status: .overdue)
        let snoozedDose = dose(status: .snoozed)

        for dose in [takenDose, takenLateDose, skippedDose, upcomingDose, dueDose, overdueDose, snoozedDose] {
            dose.medication = medication
            medication.scheduledDoses.append(dose)
            context.insert(dose)
        }

        let doseEvent = DoseEvent(action: .taken, medication: medication, scheduledDose: takenDose)
        medication.doseEvents.append(doseEvent)
        context.insert(doseEvent)

        let refillEvent = RefillEvent(quantity: 30, medication: medication)
        medication.refillEvents.append(refillEvent)
        context.insert(refillEvent)

        try context.save()

        try MedicationRepository.archive(medication, in: context)

        #expect(medication.isActive == false)

        let remainingStatuses = Set(medication.scheduledDoses.map(\.status))
        #expect(remainingStatuses == [.takenOnTime, .takenLate, .skipped])
        #expect(medication.scheduledDoses.count == 3)

        // History is untouched.
        #expect(medication.doseEvents.count == 1)
        #expect(medication.refillEvents.count == 1)
    }

    @Test func archivingMedicationWithNoDosesIsSafe() throws {
        let context = try makeContext()
        let medication = Medication(displayName: "Bare Med")
        context.insert(medication)
        try context.save()

        try MedicationRepository.archive(medication, in: context)

        #expect(medication.isActive == false)
        #expect(medication.scheduledDoses.isEmpty)
    }
}
