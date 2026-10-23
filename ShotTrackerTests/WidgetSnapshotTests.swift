import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// Guards the widget's value-type `WidgetDoseItem.resolvedStatus` against drift from the
/// app's `DoseStatusEvaluator.effectiveStatus` — the widget re-resolves status in its own
/// process from a snapshot, so the two must agree for the same dose at the same instant.
@MainActor
struct WidgetStatusParityTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: h, minute: min))!
    }

    /// Every kind of dose the evaluator distinguishes.
    private static func fixtures() -> [ScheduledDose] {
        // Flexible window 6:00–12:00.
        let window = ScheduledDose(
            occurrenceKey: "window", regimenVersion: 1,
            scheduledAt: date(6), timingLabel: "morning",
            reminderWindowMinutes: 60, graceWindowMinutes: 180,
            windowEndAt: date(12)
        )
        // Exact-time 8:00 with 3h grace → overdue after 11:00.
        let exact = ScheduledDose(
            occurrenceKey: "exact", regimenVersion: 1,
            scheduledAt: date(8), timingLabel: "8:00-am",
            reminderWindowMinutes: 60, graceWindowMinutes: 180
        )
        let snoozed = ScheduledDose(
            occurrenceKey: "snoozed", regimenVersion: 1,
            scheduledAt: date(6), timingLabel: "morning",
            reminderWindowMinutes: 60, graceWindowMinutes: 180,
            windowEndAt: date(12)
        )
        snoozed.snoozedUntil = date(15)

        let takenOnTime = ScheduledDose(
            occurrenceKey: "taken-on", regimenVersion: 1,
            scheduledAt: date(6), timingLabel: "morning",
            reminderWindowMinutes: 60, graceWindowMinutes: 180,
            windowEndAt: date(12), status: .takenOnTime, lastAction: .taken
        )
        let takenLate = ScheduledDose(
            occurrenceKey: "taken-late", regimenVersion: 1,
            scheduledAt: date(6), timingLabel: "morning",
            reminderWindowMinutes: 60, graceWindowMinutes: 180,
            windowEndAt: date(12), status: .takenLate, lastAction: .taken
        )
        let skipped = ScheduledDose(
            occurrenceKey: "skipped", regimenVersion: 1,
            scheduledAt: date(6), timingLabel: "morning",
            reminderWindowMinutes: 60, graceWindowMinutes: 180,
            windowEndAt: date(12), status: .skipped, lastAction: .skipped
        )
        return [window, exact, snoozed, takenOnTime, takenLate, skipped]
    }

    @Test func resolvedStatusMatchesEvaluatorAcrossTheDay() {
        let evaluator = DoseStatusEvaluator()
        let probes = [Self.date(5), Self.date(6), Self.date(9), Self.date(11), Self.date(12), Self.date(12, 1), Self.date(14), Self.date(16), Self.date(23)]

        for dose in Self.fixtures() {
            let item = WidgetSnapshotWriter.makeItem(dose)
            for now in probes {
                let expected = evaluator.effectiveStatus(for: dose, now: now)
                let actual = item.resolvedStatus(now: now)
                #expect(
                    actual.rawValue == expected.rawValue,
                    "dose \(dose.occurrenceKey) at \(now): widget=\(actual.rawValue) evaluator=\(expected.rawValue)"
                )
            }
        }
    }
}

/// Verifies the writer's projection: overdue first, then upcoming-today; completed doses
/// excluded; item cap respected.
@MainActor
struct WidgetSnapshotWriterTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Medication.self, MedicationRegimen.self, RegimenPhase.self,
            ReminderPolicy.self, ScheduledDose.self, DoseEvent.self, RefillEvent.self,
        ])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        return ModelContext(container)
    }

    private func dose(_ key: String, start: Date, end: Date, status: DoseStatus = .upcoming, lastAction: DoseActionType = .pending) -> ScheduledDose {
        ScheduledDose(
            occurrenceKey: key, regimenVersion: 1,
            scheduledAt: start, timingLabel: "slot",
            reminderWindowMinutes: 60, graceWindowMinutes: 60,
            windowEndAt: end, status: status, lastAction: lastAction
        )
    }

    @Test func ordersOverdueFirstAndExcludesCompleted() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let base = cal.startOfDay(for: .now)
        func at(_ h: Int) -> Date { cal.date(byAdding: .hour, value: h, to: base)! }
        let now = at(12)

        // overdue (window closed 08:00), due (11–13), upcoming tonight (20–22), completed today.
        let overdue = dose("overdue", start: at(7), end: at(8))
        let due = dose("due", start: at(11), end: at(13))
        let upcoming = dose("upcoming", start: at(20), end: at(22))
        let completed = dose("completed", start: at(9), end: at(10), status: .takenOnTime, lastAction: .taken)

        for d in [upcoming, completed, overdue, due] { context.insert(d) }
        try context.save()

        let snapshot = WidgetSnapshotWriter.buildSnapshot(
            context: context,
            evaluator: DoseStatusEvaluator(),
            preferences: .default,
            now: now
        )

        let keys = snapshot.items.map(\.occurrenceKey)
        #expect(keys == ["overdue", "due", "upcoming"])
        #expect(!keys.contains("completed"))
        #expect(snapshot.showMedicationNames == true)
    }

    @Test func respectsItemLimit() throws {
        let context = try makeContext()
        let cal = Calendar.current
        let base = cal.startOfDay(for: .now)
        func at(_ h: Int, _ m: Int) -> Date { cal.date(byAdding: .minute, value: h * 60 + m, to: base)! }
        let now = at(12, 0)

        // 15 overdue doses (all windows closed before noon).
        for i in 0..<15 {
            context.insert(dose("od-\(i)", start: at(1, i), end: at(2, i)))
        }
        try context.save()

        let snapshot = WidgetSnapshotWriter.buildSnapshot(
            context: context,
            evaluator: DoseStatusEvaluator(),
            preferences: .default,
            now: now
        )
        #expect(snapshot.items.count == WidgetSnapshotWriter.itemLimit)
    }
}
