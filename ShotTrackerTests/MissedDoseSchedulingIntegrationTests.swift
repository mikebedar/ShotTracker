import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// End-to-end through a real (in-memory) SwiftData store: marking a rolling-schedule
/// dose taken late should re-materialize the future grid shifted to the actual date.
@MainActor
struct MissedDoseSchedulingIntegrationTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Medication.self, MedicationRegimen.self, RegimenPhase.self,
            ReminderPolicy.self, ScheduledDose.self, DoseEvent.self, RefillEvent.self,
        ])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func takingRollingDoseLateReshiftsMaterializedGrid() throws {
        let context = try makeContext()
        let engine = DoseScheduleEngine()
        let anchor = Self.date(2026, 7, 7) // Tuesday

        let medication = Medication(displayName: "Weekly Shot", kind: .injection)
        let regimen = MedicationRegimen(
            anchorDate: anchor,
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: [3]),
            timings: [DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))],
            createdAt: anchor,
            missedDosePolicy: .rescheduleFromLastDose,
            medication: medication
        )
        medication.regimens = [regimen]
        context.insert(medication)
        context.insert(regimen)
        try context.save()

        // Materialize the initial fixed grid (no doses taken yet → anchored on Tuesdays).
        let referenceDate = Self.date(2026, 7, 8, 9) // "now" = Wednesday morning
        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: .default, referenceDate: referenceDate)

        let tuesdayDoses = medication.scheduledDoses.filter { Self.calendar.component(.weekday, from: $0.scheduledAt) == 3 }
        #expect(!tuesdayDoses.isEmpty, "Before any dose is taken, the grid should sit on the anchor weekday (Tuesday)")

        // Take the Jul 7 (Tuesday) dose on Wednesday Jul 8 — a day late.
        guard let firstDose = medication.scheduledDoses.min(by: { $0.scheduledAt < $1.scheduledAt }) else {
            Issue.record("expected a materialized dose to take")
            return
        }
        try DoseRepository.applyAction(.taken, to: firstDose, now: Self.date(2026, 7, 8, 15), context: context)

        // Re-materialize: the future grid should now roll off the Wednesday take.
        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: .default, referenceDate: referenceDate)

        let futureDoses = medication.scheduledDoses
            .filter { $0.scheduledAt > Self.date(2026, 7, 8, 15) && $0.lastAction != .taken }
            .sorted { $0.scheduledAt < $1.scheduledAt }

        #expect(!futureDoses.isEmpty)
        // Every future dose should now fall on a Wednesday (weekday 4), 7 days from the
        // actual administration — not the original Tuesday grid.
        for dose in futureDoses {
            #expect(Self.calendar.component(.weekday, from: dose.scheduledAt) == 4)
        }
        // Concretely, the next dose is Jul 15 (Wed), not Jul 14 (Tue).
        let next = futureDoses.first!
        let comps = Self.calendar.dateComponents([.month, .day], from: next.scheduledAt)
        #expect(comps.month == 7 && comps.day == 15)

        // The taken dose itself is preserved as history.
        #expect(medication.scheduledDoses.contains { $0.lastAction == .taken })
    }

    @Test func fixedDailyDoseTakenLateDoesNotShift() throws {
        let context = try makeContext()
        let engine = DoseScheduleEngine()

        let medication = Medication(displayName: "BP Pill", kind: .oral)
        let regimen = MedicationRegimen(
            anchorDate: Self.date(2026, 7, 1),
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            timings: [DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))],
            createdAt: Self.date(2026, 7, 1),
            missedDosePolicy: .keepToSchedule,
            medication: medication
        )
        medication.regimens = [regimen]
        context.insert(medication)
        context.insert(regimen)
        try context.save()

        let referenceDate = Self.date(2026, 7, 10, 9)
        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: .default, referenceDate: referenceDate)

        // Take one dose very late; a fixed daily schedule must keep every future dose at 8am.
        if let aDose = medication.scheduledDoses.first(where: { $0.lastAction != .taken }) {
            try DoseRepository.applyAction(.taken, to: aDose, now: Self.date(2026, 7, 10, 20), context: context)
        }
        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: .default, referenceDate: referenceDate)

        let futureTimes = medication.scheduledDoses
            .filter { $0.scheduledAt > referenceDate }
            .map { Self.calendar.component(.hour, from: $0.scheduledAt) }
        #expect(futureTimes.allSatisfy { $0 == 8 }, "Fixed daily doses stay at their scheduled time regardless of a late take")
    }
}
