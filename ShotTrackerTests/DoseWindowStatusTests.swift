import Foundation
import Testing
@testable import ShotTracker

@MainActor
struct DoseWindowStatusTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    /// A flexible morning window 6am–noon on Jul 14.
    private static func windowDose() -> ScheduledDose {
        ScheduledDose(
            occurrenceKey: UUID().uuidString,
            regimenVersion: 1,
            scheduledAt: date(2026, 7, 14, 6),      // window start
            timingLabel: "morning",
            reminderWindowMinutes: 60,
            graceWindowMinutes: 180,
            windowEndAt: date(2026, 7, 14, 12),      // window end
            reminderAt: date(2026, 7, 14, 11)
        )
    }

    private static func exactDose() -> ScheduledDose {
        ScheduledDose(
            occurrenceKey: UUID().uuidString,
            regimenVersion: 1,
            scheduledAt: date(2026, 7, 14, 8),
            timingLabel: "8:00-am",
            reminderWindowMinutes: 60,
            graceWindowMinutes: 180  // 3h grace → overdue after 11am
            // windowEndAt nil → point behavior
        )
    }

    // MARK: window doses

    @Test func windowUpcomingBeforeStart() {
        let evaluator = DoseStatusEvaluator()
        #expect(evaluator.effectiveStatus(for: Self.windowDose(), now: Self.date(2026, 7, 14, 5)) == .upcoming)
    }

    @Test func windowDueThroughoutTheWindow() {
        let evaluator = DoseStatusEvaluator()
        let dose = Self.windowDose()
        #expect(evaluator.effectiveStatus(for: dose, now: Self.date(2026, 7, 14, 6)) == .due)   // at open
        #expect(evaluator.effectiveStatus(for: dose, now: Self.date(2026, 7, 14, 10)) == .due)  // the user's 10am case
        #expect(evaluator.effectiveStatus(for: dose, now: Self.date(2026, 7, 14, 12)) == .due)  // at close
    }

    @Test func windowOverdueOnlyAfterClose() {
        let evaluator = DoseStatusEvaluator()
        #expect(evaluator.effectiveStatus(for: Self.windowDose(), now: Self.date(2026, 7, 14, 12, 1)) == .overdue)
    }

    @Test func takingEarlyOrInWindowIsOnTime() {
        let evaluator = DoseStatusEvaluator()
        let dose = Self.windowDose()
        #expect(evaluator.completionStatus(for: dose, completionDate: Self.date(2026, 7, 14, 5)) == .takenOnTime)   // before it opens
        #expect(evaluator.completionStatus(for: dose, completionDate: Self.date(2026, 7, 14, 10)) == .takenOnTime)  // mid-window
        #expect(evaluator.completionStatus(for: dose, completionDate: Self.date(2026, 7, 14, 12)) == .takenOnTime)  // at close
    }

    @Test func takingAfterCloseIsLate() {
        let evaluator = DoseStatusEvaluator()
        #expect(evaluator.completionStatus(for: Self.windowDose(), completionDate: Self.date(2026, 7, 14, 13)) == .takenLate)
    }

    // MARK: exact-time doses keep the old point behavior

    @Test func exactTimeStillUsesGrace() {
        let evaluator = DoseStatusEvaluator()
        let dose = Self.exactDose()
        #expect(evaluator.effectiveStatus(for: dose, now: Self.date(2026, 7, 14, 7)) == .upcoming)
        #expect(evaluator.effectiveStatus(for: dose, now: Self.date(2026, 7, 14, 8)) == .due)
        #expect(evaluator.effectiveStatus(for: dose, now: Self.date(2026, 7, 14, 10, 30)) == .due)   // within 3h grace
        #expect(evaluator.effectiveStatus(for: dose, now: Self.date(2026, 7, 14, 11, 30)) == .overdue) // past grace
    }
}
