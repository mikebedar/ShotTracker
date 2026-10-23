import Foundation
import SwiftData
@testable import ShotTracker

/// Shared fixtures for the tests added in the 2026-10 health pass.
@MainActor
enum TestSupport {
    static func makeContext() throws -> ModelContext {
        let schema = Schema([
            Medication.self, MedicationRegimen.self, RegimenPhase.self,
            ReminderPolicy.self, ScheduledDose.self, DoseEvent.self, RefillEvent.self,
        ])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        // Keep the container alive for the context's lifetime.
        containers.append(container)
        return ModelContext(container)
    }

    private static var containers: [ModelContainer] = []

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9, _ min: Int = 0, calendar: Calendar? = nil) -> Date {
        (calendar ?? utc).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// An active medication with one regimen, inserted and saved.
    @discardableResult
    static func medication(
        _ name: String = "Med",
        kind: MedicationKind = .oral,
        rule: RecurrenceRule = RecurrenceRule(frequency: .daily),
        timings: [DailyTiming]? = nil,
        policy: MissedDosePolicy = .keepToSchedule,
        anchor: Date,
        createdAt: Date? = nil,
        timeZone: String = "UTC",
        context: ModelContext
    ) throws -> Medication {
        let medication = Medication(displayName: name, kind: kind)
        let regimen = MedicationRegimen(
            anchorDate: anchor,
            timeZoneIdentifier: timeZone,
            recurrenceRule: rule,
            timings: timings ?? [DailyTiming(kind: .morning)],
            createdAt: createdAt ?? anchor,
            missedDosePolicy: policy,
            medication: medication
        )
        medication.regimens = [regimen]
        context.insert(medication)
        context.insert(regimen)
        try context.save()
        return medication
    }

    static func refresh(_ context: ModelContext, at now: Date, preferences: AppPreferences? = nil) throws {
        try DoseRepository.refreshSchedules(in: context, engine: DoseScheduleEngine(), preferences: preferences ?? .default, referenceDate: now)
    }

    static func doses(of medication: Medication, onDayOf date: Date, calendar: Calendar? = nil) -> [ScheduledDose] {
        let calendar = calendar ?? utc
        return medication.scheduledDoses
            .filter { calendar.isDate($0.scheduledAt, inSameDayAs: date) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// Mirrors `EditMedicationView.saveMedication` when the schedule changed.
    static func editSchedule(
        of medication: Medication,
        timings: [DailyTiming],
        rule: RecurrenceRule = RecurrenceRule(frequency: .daily),
        policy: MissedDosePolicy = .keepToSchedule,
        at now: Date,
        context: ModelContext
    ) throws {
        let anchor = medication.regimens.active?.anchorDate ?? now
        for regimen in medication.regimens where regimen.isActive { regimen.isActive = false }
        let regimen = MedicationRegimen(
            version: (medication.regimens.map(\.version).max() ?? 0) + 1,
            anchorDate: anchor,
            timeZoneIdentifier: "UTC",
            recurrenceRule: rule,
            timings: timings,
            createdAt: now,
            missedDosePolicy: policy,
            medication: medication
        )
        medication.regimens.append(regimen)
        context.insert(regimen)
        try context.save()
    }
}
