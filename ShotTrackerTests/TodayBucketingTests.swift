import Foundation
import Testing
@testable import ShotTracker

struct TodayBucketingTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func dose(scheduledAt: Date) -> ScheduledDose {
        ScheduledDose(
            occurrenceKey: UUID().uuidString,
            regimenVersion: 1,
            scheduledAt: scheduledAt,
            timingLabel: "morning",
            reminderWindowMinutes: 60,
            graceWindowMinutes: 120
        )
    }

    @Test func bucketsDosesByTimeOfDayAndStatus() throws {
        let now = Self.date(2026, 7, 10, 11, 0)

        let overdue = Self.dose(scheduledAt: Self.date(2026, 7, 10, 8, 0))
        let oldOverdue = Self.dose(scheduledAt: Self.date(2026, 7, 7, 8, 0))
        let due = Self.dose(scheduledAt: Self.date(2026, 7, 10, 10, 30))
        let soon = Self.dose(scheduledAt: Self.date(2026, 7, 10, 13, 0))
        let later = Self.dose(scheduledAt: Self.date(2026, 7, 10, 16, 0))
        let tonight = Self.dose(scheduledAt: Self.date(2026, 7, 10, 19, 0))
        let completedToday = Self.dose(scheduledAt: Self.date(2026, 7, 10, 7, 0))
        let completedYesterday = Self.dose(scheduledAt: Self.date(2026, 7, 9, 7, 0))
        let tomorrow = Self.dose(scheduledAt: Self.date(2026, 7, 11, 8, 0))

        let statuses: [UUID: DoseStatus] = [
            overdue.id: .overdue,
            oldOverdue.id: .overdue,
            due.id: .due,
            soon.id: .upcoming,
            later.id: .upcoming,
            tonight.id: .upcoming,
            completedToday.id: .takenOnTime,
            completedYesterday.id: .takenOnTime,
            tomorrow.id: .upcoming,
        ]

        let allDoses = [overdue, oldOverdue, due, soon, later, tonight, completedToday, completedYesterday, tomorrow]

        let buckets = TodayBucketing.bucket(
            doses: allDoses,
            statusFor: { statuses[$0.id] ?? .upcoming },
            now: now,
            calendar: Self.calendar
        )

        #expect(Set(buckets.overdue.map(\.id)) == [overdue.id, oldOverdue.id])
        #expect(buckets.takeNow.map(\.id) == [due.id])
        #expect(buckets.comingUpSoon.map(\.id) == [soon.id])
        #expect(buckets.laterToday.map(\.id) == [later.id])
        #expect(buckets.tonight.map(\.id) == [tonight.id])
        #expect(buckets.completed.map(\.id) == [completedToday.id])

        let allBucketedIDs = Set(
            buckets.overdue.map(\.id) + buckets.takeNow.map(\.id) + buckets.comingUpSoon.map(\.id)
                + buckets.laterToday.map(\.id) + buckets.tonight.map(\.id) + buckets.completed.map(\.id)
        )
        #expect(!allBucketedIDs.contains(completedYesterday.id))
        #expect(!allBucketedIDs.contains(tomorrow.id))
    }

    @Test func longRangeComingUpGroupsNextOccurrencePerMedication() throws {
        let now = Self.date(2026, 7, 10, 11, 0)
        let medication = Medication(displayName: "Test Med")

        let tomorrowMorning = Self.dose(scheduledAt: Self.date(2026, 7, 11, 8, 0))
        let tomorrowEvening = Self.dose(scheduledAt: Self.date(2026, 7, 11, 18, 0))
        let nextWeek = Self.dose(scheduledAt: Self.date(2026, 7, 17, 8, 0))
        medication.scheduledDoses = [tomorrowMorning, tomorrowEvening, nextWeek]

        let groups = TodayBucketing.longRangeComingUp(
            medications: [medication],
            statusFor: { _ in .upcoming },
            engine: DoseScheduleEngine(deviceClock: .atHome),
            preferences: .default,
            forecastLimit: Self.date(2027, 1, 1, 0, 0),
            now: now,
            calendar: Self.calendar
        )

        // Only the medication's next occurrence (tomorrowMorning) should surface,
        // not every future dose — tomorrowEvening and nextWeek are later occurrences
        // of the same medication and shouldn't get their own entries.
        #expect(groups.count == 1)
        #expect(groups.first?.items.map { $0.dose.id } == [tomorrowMorning.id])
        #expect(groups.first?.items.first?.isForecasted == false)
    }
}
