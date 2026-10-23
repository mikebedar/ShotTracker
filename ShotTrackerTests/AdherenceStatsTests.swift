import Foundation
import Testing
@testable import ShotTracker

@MainActor
struct AdherenceStatsTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 12))!

    private static func daysAgo(_ days: Int, hour: Int = 8) -> Date {
        calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
            .addingTimeInterval(TimeInterval(hour * 3600))
    }

    private static func dose(_ status: DoseStatus, at date: Date, slot: String = "morning") -> ScheduledDose {
        ScheduledDose(
            occurrenceKey: UUID().uuidString,
            regimenVersion: 1,
            scheduledAt: date,
            timingLabel: slot,
            reminderWindowMinutes: 60,
            graceWindowMinutes: 60,
            status: status,
            lastAction: {
                switch status {
                case .takenOnTime, .takenLate: .taken
                case .skipped: .skipped
                default: .pending
                }
            }()
        )
    }

    private func compute(_ doses: [ScheduledDose]) -> AdherenceStats.Stats {
        AdherenceStats.compute(
            doses: doses,
            statusFor: { $0.status },
            now: Self.now,
            calendar: Self.calendar
        )
    }

    @Test func percentCountsTakenAgainstConcluded() {
        let doses = [
            Self.dose(.takenOnTime, at: Self.daysAgo(1)),
            Self.dose(.takenLate, at: Self.daysAgo(2)),
            Self.dose(.skipped, at: Self.daysAgo(3)),
            Self.dose(.overdue, at: Self.daysAgo(4)),
            Self.dose(.upcoming, at: Self.daysAgo(0, hour: 20)),  // still in play — excluded
        ]
        let stats = compute(doses)
        #expect(stats.adherencePercent == 50)  // 2 of 4 concluded
        #expect(stats.takenCount == 2)
        #expect(stats.missedCount == 2)
    }

    @Test func emptyWindowYieldsNilPercent() {
        #expect(compute([]).adherencePercent == nil)
    }

    @Test func streakEndsAtFirstMissAndSkipsEmptyDays() {
        // Weekly-style pattern: taken 2 and 9 days ago, missed 16 days ago.
        let doses = [
            Self.dose(.takenOnTime, at: Self.daysAgo(2)),
            Self.dose(.takenOnTime, at: Self.daysAgo(9)),
            Self.dose(.overdue, at: Self.daysAgo(16)),
        ]
        let stats = compute(doses)
        #expect(stats.currentStreakDays == 2)  // two dosing days in a row, empty days neutral
    }

    @Test func missTodayBreaksStreak() {
        let doses = [
            Self.dose(.skipped, at: Self.daysAgo(0)),
            Self.dose(.takenOnTime, at: Self.daysAgo(1)),
        ]
        #expect(compute(doses).currentStreakDays == 0)
    }

    @Test func mostMissedSlotPicksHighestMissCount() {
        let doses = [
            Self.dose(.overdue, at: Self.daysAgo(1), slot: "evening"),
            Self.dose(.overdue, at: Self.daysAgo(2), slot: "evening"),
            Self.dose(.skipped, at: Self.daysAgo(3), slot: "morning"),
            Self.dose(.takenOnTime, at: Self.daysAgo(4), slot: "morning"),
        ]
        #expect(compute(doses).mostMissedSlot == "evening")
    }

    @Test func dosesOlderThanWindowAreIgnored() {
        let doses = [Self.dose(.skipped, at: Self.daysAgo(45))]
        let stats = compute(doses)
        #expect(stats.adherencePercent == nil)
        #expect(stats.missedCount == 0)
    }
}
