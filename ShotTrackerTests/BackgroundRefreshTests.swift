import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// Decision 2026-10-23: a daily `BGAppRefreshTask` re-runs `refreshSchedules` and
/// re-plans notifications. `BackgroundRefresh.plan` is the planning step of a run; it
/// must be idempotent, move the window forward, and respect the 64-request budget with
/// refill reminders first.
@MainActor
struct BackgroundRefreshTests {
    private typealias T = TestSupport

    private func plan(_ context: ModelContext, at now: Date) throws -> NotificationScheduler.Plan {
        try #require(try BackgroundRefresh.plan(
            context: context, engine: DoseScheduleEngine(), evaluator: DoseStatusEvaluator(),
            preferences: .default, now: now, calendar: T.utc
        ))
    }

    private func doseCount(_ context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<ScheduledDose>())
    }

    @Test func runningTwiceChangesNothing() throws {
        let context = try T.makeContext()
        try T.medication("Metformin", timings: [DailyTiming(kind: .morning), DailyTiming(kind: .bedtime)], anchor: T.date(2026, 7, 1), context: context)
        try T.medication("Ozempic", kind: .injection, rule: RecurrenceRule(frequency: .weekly), policy: .rescheduleFromLastDose, anchor: T.date(2026, 7, 1), context: context)
        let now = T.date(2026, 7, 13, 4)

        let first = try plan(context, at: now)
        let rows = try doseCount(context)
        let second = try plan(context, at: now)

        #expect(first == second)
        #expect(try doseCount(context) == rows, "No duplicate doses")
        #expect(!first.requests.isEmpty)
        #expect(first.requests.allSatisfy { $0.fireDate > now })
        #expect(Set(first.requests.map(\.identifier)).count == first.requests.count)
    }

    @Test func aRunADayLaterMovesTheWindowForward() throws {
        let context = try T.makeContext()
        let medication = try T.medication("Metformin", anchor: T.date(2026, 7, 1), context: context)
        _ = try plan(context, at: T.date(2026, 7, 13, 4))
        let lastBefore = try #require(medication.scheduledDoses.map(\.scheduledAt).max())

        let next = try plan(context, at: T.date(2026, 7, 14, 4))
        let lastAfter = try #require(medication.scheduledDoses.map(\.scheduledAt).max())
        #expect(lastAfter == T.utc.date(byAdding: .day, value: 1, to: lastBefore))
        #expect(next.requests.first?.fireDate == T.date(2026, 7, 14, 11), "Today's morning reminder (12:00 close − 60 min)")
    }

    @Test func aTakenDoseStaysTakenAndGetsNoReminder() throws {
        let context = try T.makeContext()
        let medication = try T.medication("Metformin", anchor: T.date(2026, 7, 1), context: context)
        try T.refresh(context, at: T.date(2026, 7, 13, 7))
        let today = try #require(T.doses(of: medication, onDayOf: T.date(2026, 7, 13)).first)
        try DoseRepository.applyAction(.taken, to: today, now: T.date(2026, 7, 13, 8), context: context)

        let result = try plan(context, at: T.date(2026, 7, 13, 9))
        #expect(!result.requests.contains { $0.occurrenceKey == today.occurrenceKey })
        #expect(T.doses(of: medication, onDayOf: T.date(2026, 7, 13)).count == 1)
        #expect(today.lastAction == .taken)
    }

    @Test func theBudgetKeepsRefillRemindersFirst() throws {
        let context = try T.makeContext()
        for index in 0..<8 {
            let medication = try T.medication(
                "Med \(index)",
                timings: [DailyTiming(kind: .morning), DailyTiming(kind: .noon), DailyTiming(kind: .evening), DailyTiming(kind: .bedtime)],
                anchor: T.date(2026, 7, 1), context: context
            )
            if index < 2 {
                // ~10 days of supply at 4 a day: runs out around Jul 23, reminder Jul 20.
                medication.supplyUnitLabel = "tablets"
                medication.unitsPerContainer = 40
                medication.supplyContainers = [40]
            }
        }
        try context.save()

        let result = try plan(context, at: T.date(2026, 7, 13, 4))
        #expect(result.requests.count == NotificationPlanner.systemLimit)
        #expect(result.candidateCount > NotificationPlanner.systemLimit)
        #expect(result.requests.filter { $0.identifier.hasPrefix("refill-") }.count == 2)
    }

    @Test func theNextRunIsEarlyTomorrowMorningOnTheLocalClock() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        func ny(_ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
            newYork.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min))!
        }
        #expect(BackgroundRefresh.nextEarliestBegin(after: ny(7, 14, 10), calendar: newYork) == ny(7, 15, 4))
        #expect(BackgroundRefresh.nextEarliestBegin(after: ny(7, 14, 3), calendar: newYork) == ny(7, 14, 4))
        #expect(BackgroundRefresh.nextEarliestBegin(after: ny(7, 14, 4), calendar: newYork) == ny(7, 15, 4))
        // Across the spring-forward night (2:00 → 3:00 on Mar 8): still 4:00 local.
        let afterDST = BackgroundRefresh.nextEarliestBegin(after: ny(3, 7, 22), calendar: newYork)
        #expect(afterDST == ny(3, 8, 4))
        #expect(afterDST.timeIntervalSince(ny(3, 7, 22)) == 5 * 3600)
    }
}
