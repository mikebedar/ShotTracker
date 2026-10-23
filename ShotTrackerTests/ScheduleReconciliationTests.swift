import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// Regressions found in the 2026-10 health pass: duplicated or vanished doses when a
/// dose's key changes, rolling schedules with several doses a day, finished tapers that
/// never ended, and missed doses that disappeared from history.
@MainActor
struct ScheduleReconciliationTests {
    private typealias T = TestSupport
    private let calendar = TestSupport.utc

    @Test func movingARoutineWindowAfterTakingTodaysDoseDoesNotDuplicateIt() throws {
        let context = try T.makeContext()
        let now = T.date(2026, 7, 13, 10)
        let medication = try T.medication(anchor: T.date(2026, 7, 1), context: context)
        try T.refresh(context, at: now)

        let today = T.doses(of: medication, onDayOf: now)
        #expect(today.count == 1)
        try DoseRepository.applyAction(.taken, to: today[0], now: now, context: context)

        // The window start is part of the occurrence key, so this re-keys every dose.
        var preferences = AppPreferences.default
        preferences.defaultSlotWindows[TimingAnchorKind.morning.rawValue] = DoseWindow(
            start: ClockTime(hour: 7, minute: 0), end: ClockTime(hour: 12, minute: 0)
        )
        try T.refresh(context, at: now, preferences: preferences)

        let after = T.doses(of: medication, onDayOf: now)
        #expect(after.count == 1, "Today's taken morning dose came back as a second, due one")
        #expect(after.first?.lastAction == .taken)

        let tomorrow = T.doses(of: medication, onDayOf: T.date(2026, 7, 14))
        #expect(tomorrow.count == 1)
        #expect(tomorrow.first.map { calendar.component(.hour, from: $0.scheduledAt) } == 7)
    }

    @Test func legacyExactTimeLabelIsReconciledByInstant() throws {
        let context = try T.makeContext()
        let now = T.date(2026, 7, 13, 10)
        let medication = try T.medication(
            timings: [DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 9, minute: 0))],
            anchor: T.date(2026, 7, 1),
            context: context
        )
        // A row written before the label change: localized "9:00-am", no timing id, taken.
        let legacy = ScheduledDose(
            occurrenceKey: "\(medication.id.uuidString)-v1-202607130900-9:00-am",
            regimenVersion: 1,
            scheduledAt: T.date(2026, 7, 13, 9),
            timingLabel: "9:00-am",
            reminderWindowMinutes: 60,
            graceWindowMinutes: 180,
            status: .takenOnTime,
            lastAction: .taken,
            medication: medication
        )
        legacy.completedAt = T.date(2026, 7, 13, 9, 5)
        medication.scheduledDoses.append(legacy)
        context.insert(legacy)
        try context.save()

        try T.refresh(context, at: now)

        let today = T.doses(of: medication, onDayOf: now)
        #expect(today.count == 1)
        #expect(today.first?.id == legacy.id)
        #expect(T.doses(of: medication, onDayOf: T.date(2026, 7, 14)).first?.timingLabel == "at-0900")
    }

    @Test func editingAfterTheMorningDoseKeepsTodaysEveningDose() throws {
        let context = try T.makeContext()
        let now = T.date(2026, 7, 13, 10)
        let morning = DailyTiming(kind: .morning)
        let evening = DailyTiming(kind: .evening)
        let medication = try T.medication(timings: [morning, evening], anchor: T.date(2026, 7, 1), context: context)
        try T.refresh(context, at: now)

        let todaysMorning = try #require(T.doses(of: medication, onDayOf: now).first)
        try DoseRepository.applyAction(.taken, to: todaysMorning, now: now, context: context)

        // Move only the evening dose's window (a new regimen version).
        var movedEvening = evening
        movedEvening.customWindow = DoseWindow(start: ClockTime(hour: 18, minute: 0), end: ClockTime(hour: 22, minute: 0))
        try T.editSchedule(of: medication, timings: [morning, movedEvening], at: now, context: context)
        try T.refresh(context, at: now)

        let today = T.doses(of: medication, onDayOf: now)
        #expect(today.count == 2, "Expected the taken morning dose and the moved evening dose: \(today.map(\.timingLabel))")
        #expect(today.first?.lastAction == .taken)
        #expect(today.last.map { calendar.component(.hour, from: $0.scheduledAt) } == 18)
    }

    @Test func missedDosesSurviveLeavingTheLookbackWindow() throws {
        let context = try T.makeContext()
        let medication = try T.medication(anchor: T.date(2026, 7, 1), context: context)
        try T.refresh(context, at: T.date(2026, 7, 10, 13))
        let missedBefore = medication.scheduledDoses.filter { $0.scheduledAt < T.date(2026, 7, 10, 0) }.count
        #expect(missedBefore == 7)

        // Ten days later the first refresh's past rows are outside the 7-day lookback.
        let later = T.date(2026, 7, 20, 13)
        try T.refresh(context, at: later)
        let stillThere = medication.scheduledDoses.filter { $0.scheduledAt < T.date(2026, 7, 10, 0) }.count
        #expect(stillThere == 7, "Untouched past doses were pruned once they left the lookback window")

        let stats = AdherenceStats.compute(
            doses: medication.scheduledDoses,
            statusFor: { DoseStatusEvaluator().effectiveStatus(for: $0, now: later) },
            now: later,
            calendar: calendar
        )
        #expect(stats.missedCount == 18)  // Jul 3 … Jul 20 (today's window closed at noon)
        #expect(stats.adherencePercent == 0)
    }

    @Test func rollingTwiceDailyKeepsTheEveningDoseAfterTheMorningOne() throws {
        let context = try T.makeContext()
        let now = T.date(2026, 7, 13, 10)
        let medication = try T.medication(
            kind: .injection,
            timings: [DailyTiming(kind: .morning), DailyTiming(kind: .evening)],
            policy: .rescheduleFromLastDose,
            anchor: T.date(2026, 7, 1),
            context: context
        )
        try T.refresh(context, at: now)
        let todaysMorning = try #require(T.doses(of: medication, onDayOf: now).first)
        try DoseRepository.applyAction(.taken, to: todaysMorning, now: now, context: context)
        try T.refresh(context, at: now)

        let today = T.doses(of: medication, onDayOf: now)
        #expect(today.count == 2, "Taking the morning dose erased today's evening dose: \(today.map(\.timingLabel))")
        #expect(today.last?.timingLabel == "evening")
        #expect(today.last?.isUntouched == true)
        #expect(T.doses(of: medication, onDayOf: T.date(2026, 7, 14)).count == 2)
    }

    @Test func rollingSingleDailyDoseStillStartsTomorrow() throws {
        let context = try T.makeContext()
        let now = T.date(2026, 7, 13, 10)
        let medication = try T.medication(kind: .injection, policy: .rescheduleFromLastDose, anchor: T.date(2026, 7, 1), context: context)
        try T.refresh(context, at: now)
        let todays = try #require(T.doses(of: medication, onDayOf: now).first)
        try DoseRepository.applyAction(.taken, to: todays, now: now, context: context)
        try T.refresh(context, at: now)

        #expect(T.doses(of: medication, onDayOf: now).count == 1)
        #expect(T.doses(of: medication, onDayOf: T.date(2026, 7, 14)).count == 1)
    }

    @Test func phasedRegimenEndsAfterItsLastPhaseAndCountsIntervalsFromThePhaseStart() {
        let medication = Medication(displayName: "Taper")
        let regimen = MedicationRegimen(
            anchorDate: T.date(2026, 7, 1, 0),
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .phased),
            timings: [DailyTiming(kind: .morning)],
            createdAt: T.date(2026, 7, 1, 0),
            medication: medication
        )
        regimen.phases = [
            RegimenPhase(title: "High", startDayOffset: 0, durationDays: 3, recurrenceRule: RecurrenceRule(frequency: .daily), timings: []),
            RegimenPhase(title: "Low", startDayOffset: 3, durationDays: 3, recurrenceRule: RecurrenceRule(frequency: .intervalDays, intervalDays: 2), timings: []),
        ]

        let occurrences = DoseScheduleEngine().generateOccurrences(
            for: regimen, medicationID: medication.id,
            from: T.date(2026, 7, 1, 0), through: T.date(2026, 7, 20, 0),
            preferences: .default
        )
        let days = occurrences.map { calendar.component(.day, from: $0.scheduledAt) }
        #expect(days == [1, 2, 3, 4, 6])
    }

    @Test func snoozingAnUpcomingDoseDoesNothing() throws {
        let context = try T.makeContext()
        let now = T.date(2026, 7, 13, 10)
        let medication = try T.medication(timings: [DailyTiming(kind: .evening)], anchor: T.date(2026, 7, 1), context: context)
        try T.refresh(context, at: now)
        let evening = try #require(T.doses(of: medication, onDayOf: now).first)

        try DoseRepository.applyAction(.snoozed, to: evening, now: now, context: context)

        #expect(evening.snoozedUntil == nil)
        #expect(evening.events.isEmpty)
        #expect(DoseStatusEvaluator().effectiveStatus(for: evening, now: now) == .upcoming)
    }

    @Test func archivingKeepsTheEventsOfSnoozedDoses() throws {
        let context = try T.makeContext()
        let now = T.date(2026, 7, 13, 10)
        let medication = try T.medication(anchor: T.date(2026, 7, 1), context: context)
        try T.refresh(context, at: now)
        let due = try #require(T.doses(of: medication, onDayOf: now).first)
        try DoseRepository.applyAction(.snoozed, to: due, now: now, context: context)

        try MedicationRepository.archive(medication, in: context)

        let events = try context.fetch(FetchDescriptor<DoseEvent>())
        #expect(events.count == 1)
        #expect(events.first?.action == .snoozed)
        #expect(events.first?.medication?.id == medication.id)
    }

    @Test func occurrenceKeysUseTheRegimensTimeZone() {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let sixAM = losAngeles.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 6))!
        let id = UUID()
        let key = DoseScheduleEngine.occurrenceKey(medicationID: id, version: 2, scheduledAt: sixAM, label: "morning", calendar: losAngeles)
        #expect(key == "\(id.uuidString)-v2-202607130600-morning")
    }
}
