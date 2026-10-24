import Foundation
import Testing
@testable import ShotTracker

@MainActor
struct DoseForecastServiceTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func medication(anchorDate: Date, rule: RecurrenceRule) -> Medication {
        let medication = Medication(displayName: "Test Med")
        // createdAt pinned to the anchor: generation is floored at the regimen version's
        // creation day, and these tests use fixed dates that drift into the past.
        let regimen = MedicationRegimen(
            anchorDate: anchorDate,
            recurrenceRule: rule,
            timings: [DailyTiming(kind: .morning)],
            createdAt: anchorDate,
            medication: medication
        )
        medication.regimens.append(regimen)
        return medication
    }

    @Test func dailyMedicationForecastsBeyondMaterializationWindow() {
        // Well beyond the app's 90-day materialization window from any realistic "today".
        let anchor = Self.date(2026, 1, 1, 8, 0)
        let medication = Self.medication(anchorDate: anchor, rule: RecurrenceRule(frequency: .daily))

        let rangeStart = Self.date(2026, 6, 1, 0, 0)
        let rangeEnd = Self.date(2026, 6, 10, 0, 0)

        let items = DoseForecastService.occurrences(
            for: [medication],
            engine: DoseScheduleEngine(deviceClock: .atHome),
            in: rangeStart...rangeEnd,
            preferences: .default
        )

        #expect(items.count == 10)
        #expect(items.allSatisfy { $0.isForecasted })
        #expect(items.allSatisfy { $0.status == .upcoming })
        #expect(items.allSatisfy { $0.medication?.id == medication.id })
    }

    @Test func forecastRespectsFutureAnchorDate() {
        // A medication added today with a schedule starting next month shouldn't
        // fabricate occurrences before it existed.
        let anchor = Self.date(2026, 9, 1, 8, 0)
        let medication = Self.medication(anchorDate: anchor, rule: RecurrenceRule(frequency: .daily))

        let rangeStart = Self.date(2026, 8, 25, 0, 0)
        let rangeEnd = Self.date(2026, 9, 5, 0, 0)

        let items = DoseForecastService.occurrences(
            for: [medication],
            engine: DoseScheduleEngine(deviceClock: .atHome),
            in: rangeStart...rangeEnd,
            preferences: .default
        )

        let anchorDay = Self.calendar.startOfDay(for: anchor)
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.dose.scheduledAt >= anchorDay })
    }

    @Test func nextOccurrenceFindsEarliestAfterDate() {
        let anchor = Self.date(2026, 1, 1, 8, 0)
        let medication = Self.medication(anchorDate: anchor, rule: RecurrenceRule(frequency: .daily))

        let after = Self.date(2026, 6, 1, 9, 0)
        let limit = Self.date(2026, 7, 1, 0, 0)

        let next = DoseForecastService.nextOccurrence(
            for: medication, engine: DoseScheduleEngine(deviceClock: .atHome), after: after, limit: limit, preferences: .default
        )

        #expect(next != nil)
        #expect(next?.isForecasted == true)
        #expect((next?.dose.scheduledAt ?? .distantPast) > after)
    }

    @Test func longRangeComingUpFallsBackToForecastForMedicationWithNoPersistedDose() {
        // No persisted `scheduledDoses` at all — mirrors an infrequent regimen whose next
        // "on" day fell outside the materialization window that would have been generated.
        let anchor = Self.date(2026, 1, 1, 8, 0)
        let medication = Self.medication(
            anchorDate: anchor,
            rule: RecurrenceRule(frequency: .cycle, cycleOnDays: 1, cycleOffDays: 120)
        )

        let now = Self.date(2026, 3, 1, 9, 0)
        let forecastLimit = Self.date(2027, 1, 1, 0, 0)

        let groups = TodayBucketing.longRangeComingUp(
            medications: [medication],
            statusFor: { _ in .upcoming },
            engine: DoseScheduleEngine(deviceClock: .atHome),
            preferences: .default,
            forecastLimit: forecastLimit,
            now: now,
            calendar: Self.calendar
        )

        let allItems = groups.flatMap(\.items)
        #expect(!allItems.isEmpty)
        #expect(allItems.allSatisfy { $0.isForecasted })
        #expect(allItems.allSatisfy { $0.medication?.id == medication.id })
    }

    @Test func longRangeComingUpPrefersPersistedDoseOverForecast() {
        // When a real ScheduledDose already exists in the window, it should win over
        // computing a forecast — persisted doses carry real state (status, snooze, etc.).
        let anchor = Self.date(2026, 1, 1, 8, 0)
        let medication = Self.medication(anchorDate: anchor, rule: RecurrenceRule(frequency: .daily))

        let persistedDose = ScheduledDose(
            occurrenceKey: "persisted-key",
            regimenVersion: 1,
            scheduledAt: Self.date(2026, 3, 2, 8, 0),
            timingLabel: "morning",
            reminderWindowMinutes: 60,
            graceWindowMinutes: 180,
            status: .upcoming
        )
        medication.scheduledDoses = [persistedDose]

        let now = Self.date(2026, 3, 1, 9, 0)
        let groups = TodayBucketing.longRangeComingUp(
            medications: [medication],
            statusFor: { _ in .upcoming },
            engine: DoseScheduleEngine(deviceClock: .atHome),
            preferences: .default,
            forecastLimit: Self.date(2027, 1, 1, 0, 0),
            now: now,
            calendar: Self.calendar
        )

        let allItems = groups.flatMap(\.items)
        #expect(allItems.count == 1)
        #expect(allItems.first?.isForecasted == false)
        #expect(allItems.first?.dose.occurrenceKey == "persisted-key")
    }
}
