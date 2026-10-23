import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// Regression: editing a medication's timing creates a new regimen version; the
/// re-materialized grid must not leave duplicate doses per day (old-version rows
/// surviving alongside the new version's).
@MainActor
struct RegimenEditRegressionTests {
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

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Mirrors EditMedicationView.saveMedication's regimen-versioning: deactivate all
    /// active regimens, append a new highest-version one.
    private func applyEdit(
        to medication: Medication,
        context: ModelContext,
        newTimings: [DailyTiming],
        anchorDate: Date,
        policy: MissedDosePolicy,
        editedAt: Date
    ) throws {
        for existing in medication.regimens where existing.isActive {
            existing.isActive = false
        }
        let newVersion = (medication.regimens.map(\.version).max() ?? 0) + 1
        let regimen = MedicationRegimen(
            version: newVersion,
            anchorDate: anchorDate,
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            timings: newTimings,
            createdAt: editedAt,
            missedDosePolicy: policy,
            medication: medication
        )
        medication.regimens.append(regimen)
        context.insert(regimen)
        try context.save()
    }

    @Test func editingTimingAfterTakingTodayDoesNotDuplicateFutureDays() throws {
        let context = try makeContext()
        let engine = DoseScheduleEngine()
        let anchor = Self.date(2026, 7, 1)
        let now = Self.date(2026, 7, 13, 10)

        let medication = Medication(displayName: "Daily Pill", kind: .oral)
        let regimen = MedicationRegimen(
            anchorDate: anchor,
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            timings: [DailyTiming(kind: .morning)],
            createdAt: anchor,
            missedDosePolicy: .keepToSchedule,
            medication: medication
        )
        medication.regimens = [regimen]
        context.insert(medication)
        context.insert(regimen)
        try context.save()

        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: .default, referenceDate: now)

        // Take today's dose.
        let todayDose = medication.scheduledDoses.first {
            Self.calendar.isDate($0.scheduledAt, inSameDayAs: now)
        }
        #expect(todayDose != nil)
        try DoseRepository.applyAction(.taken, to: todayDose!, now: now, context: context)

        // Edit: change the timing from morning to noon (new regimen version v2).
        try applyEdit(
            to: medication,
            context: context,
            newTimings: [DailyTiming(kind: .noon)],
            anchorDate: anchor,
            policy: .keepToSchedule,
            editedAt: now
        )
        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: .default, referenceDate: now)

        // Group all non-completed doses by day; every FUTURE day must have exactly one.
        let startOfTomorrow = Self.calendar.date(byAdding: .day, value: 1, to: Self.calendar.startOfDay(for: now))!
        let futureDoses = medication.scheduledDoses.filter { $0.scheduledAt >= startOfTomorrow }
        let byDay = Dictionary(grouping: futureDoses) { Self.calendar.startOfDay(for: $0.scheduledAt) }

        for (day, doses) in byDay.sorted(by: { $0.key < $1.key }) {
            #expect(
                doses.count == 1,
                "Expected 1 dose on \(day), found \(doses.count): \(doses.map { "\($0.timingLabel) v\($0.regimenVersion) events=\($0.events.count) completedAt=\(String(describing: $0.completedAt))" })"
            )
        }

        // And past days should not have gained phantom new-version doses either:
        // the only surviving pre-edit row is the taken one.
        let pastAndToday = medication.scheduledDoses.filter { $0.scheduledAt < startOfTomorrow }
        let takenCount = pastAndToday.filter { $0.lastAction == .taken }.count
        #expect(takenCount == 1)
        let untouchedPast = pastAndToday.filter { $0.lastAction != .taken }
        #expect(
            untouchedPast.count <= 1,
            "Past days should not accumulate phantom doses from the new version: \(untouchedPast.map { "\($0.timingLabel) v\($0.regimenVersion) at \($0.scheduledAt)" })"
        )
    }

    /// Data damaged by the pre-fix behavior (phantom past doses fabricated under a new
    /// regimen version) self-heals: the next refresh prunes them as untouched stale rows.
    @Test func existingPhantomPastDosesArePrunedOnNextRefresh() throws {
        let context = try makeContext()
        let engine = DoseScheduleEngine()
        let anchor = Self.date(2026, 7, 1)
        let now = Self.date(2026, 7, 13, 10)

        let medication = Medication(displayName: "Damaged Med", kind: .oral)
        let regimen = MedicationRegimen(
            version: 2,
            anchorDate: anchor,
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            timings: [DailyTiming(kind: .noon)],
            createdAt: now,
            missedDosePolicy: .keepToSchedule,
            medication: medication
        )
        medication.regimens = [regimen]
        context.insert(medication)
        context.insert(regimen)

        // Simulate the pre-fix damage: v2 phantom doses materialized for the past week.
        for dayOffset in 1...7 {
            let day = Self.calendar.date(byAdding: .day, value: -dayOffset, to: Self.calendar.startOfDay(for: now))!
            let phantom = ScheduledDose(
                occurrenceKey: "phantom-\(dayOffset)",
                regimenVersion: 2,
                scheduledAt: Self.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!,
                timingLabel: "noon",
                reminderWindowMinutes: 60,
                graceWindowMinutes: 180,
                medication: medication
            )
            medication.scheduledDoses.append(phantom)
            context.insert(phantom)
        }
        try context.save()

        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: .default, referenceDate: now)

        let startOfToday = Self.calendar.startOfDay(for: now)
        let pastDoses = medication.scheduledDoses.filter { $0.scheduledAt < startOfToday }
        #expect(pastDoses.isEmpty, "Untouched phantom past doses should be pruned: \(pastDoses.map(\.occurrenceKey))")
    }

    @Test func editingRollingMedicationAfterTakingDoesNotDuplicate() throws {
        let context = try makeContext()
        let engine = DoseScheduleEngine()
        let anchor = Self.date(2026, 7, 1)
        let now = Self.date(2026, 7, 13, 10)

        let medication = Medication(displayName: "Daily Rolling", kind: .injection)
        let regimen = MedicationRegimen(
            anchorDate: anchor,
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            timings: [DailyTiming(kind: .morning)],
            createdAt: anchor,
            missedDosePolicy: .rescheduleFromLastDose,
            medication: medication
        )
        medication.regimens = [regimen]
        context.insert(medication)
        context.insert(regimen)
        try context.save()

        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: .default, referenceDate: now)

        let todayDose = medication.scheduledDoses.first {
            Self.calendar.isDate($0.scheduledAt, inSameDayAs: now)
        }
        #expect(todayDose != nil)
        try DoseRepository.applyAction(.taken, to: todayDose!, now: now, context: context)

        try applyEdit(
            to: medication,
            context: context,
            newTimings: [DailyTiming(kind: .noon)],
            anchorDate: anchor,
            policy: .rescheduleFromLastDose,
            editedAt: now
        )
        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: .default, referenceDate: now)

        let startOfTomorrow = Self.calendar.date(byAdding: .day, value: 1, to: Self.calendar.startOfDay(for: now))!
        let futureDoses = medication.scheduledDoses.filter { $0.scheduledAt >= startOfTomorrow }
        let byDay = Dictionary(grouping: futureDoses) { Self.calendar.startOfDay(for: $0.scheduledAt) }

        for (day, doses) in byDay.sorted(by: { $0.key < $1.key }) {
            #expect(
                doses.count == 1,
                "Expected 1 dose on \(day), found \(doses.count): \(doses.map { "\($0.timingLabel) v\($0.regimenVersion)" })"
            )
        }
    }
}
