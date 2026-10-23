import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// Decision 2026-10-23: a snooze shifts only that dose, by the snooze length. The offset
/// is cumulative per dose (`ScheduledDose.snoozeOffsetMinutes`, also on each `DoseEvent`),
/// moves the deadline (window end + offset) and the reminder (to the snooze end), and
/// undoing a snooze takes its minutes back. On time vs late is still the original window.
@MainActor
struct SnoozeOffsetTests {
    private typealias T = TestSupport

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// A daily morning (6:00–12:00 UTC) medication materialized on 2026-07-13, and that
    /// day's dose. No reminder policy, so a snooze is the default 20 minutes.
    private func morningDose() throws -> (ModelContext, Medication, ScheduledDose) {
        let context = try T.makeContext()
        let medication = try T.medication("Metformin", anchor: T.date(2026, 7, 1), context: context)
        try T.refresh(context, at: T.date(2026, 7, 13, 7))
        let dose = try #require(T.doses(of: medication, onDayOf: T.date(2026, 7, 13)).first)
        return (context, medication, dose)
    }

    // MARK: Status and deadline

    @Test func aSnoozeMovesOnlyTheDeadlineByItsLength() throws {
        let (context, _, dose) = try morningDose()
        let evaluator = DoseStatusEvaluator()

        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 10), context: context)

        #expect(dose.snoozeOffsetMinutes == 20)
        #expect(dose.snoozedUntil == T.date(2026, 7, 13, 10, 20))
        #expect(dose.windowEnd == T.date(2026, 7, 13, 12))
        #expect(dose.deadline == T.date(2026, 7, 13, 12, 20))
        #expect(evaluator.effectiveStatus(for: dose, now: T.date(2026, 7, 13, 10, 10)) == .snoozed)
        #expect(evaluator.effectiveStatus(for: dose, now: T.date(2026, 7, 13, 10, 30)) == .due)
        #expect(evaluator.effectiveStatus(for: dose, now: T.date(2026, 7, 13, 12, 15)) == .due)
        #expect(evaluator.effectiveStatus(for: dose, now: T.date(2026, 7, 13, 12, 21)) == .overdue)
        // The old rule stretched the whole window: due until 16:20.
        #expect(evaluator.effectiveStatus(for: dose, now: T.date(2026, 7, 13, 14)) == .overdue)
    }

    @Test func onTimeIsJudgedAgainstTheOriginalWindow() throws {
        let (context, _, dose) = try morningDose()
        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 11, 50), context: context)
        try DoseRepository.applyAction(.taken, to: dose, now: T.date(2026, 7, 13, 12, 15), context: context)

        #expect(dose.status == .takenLate)
        #expect(dose.minutesLate == 15)
        #expect(dose.snoozeOffset == 20, "Taking a dose keeps the snoozes that came before it")
        let taken = try #require(dose.events.first { $0.action == .taken })
        #expect(taken.minutesLate == 15)
        #expect(taken.snoozeOffsetMinutes == 20)
        #expect(SnoozeWording.eventTitle(for: taken) == "Taken 15 min late · snoozed 20 min")

        let (context2, _, onTime) = try morningDose()
        try DoseRepository.applyAction(.snoozed, to: onTime, now: T.date(2026, 7, 13, 11, 30), context: context2)
        try DoseRepository.applyAction(.taken, to: onTime, now: T.date(2026, 7, 13, 11, 55), context: context2)
        #expect(onTime.status == .takenOnTime)
        #expect(SnoozeWording.eventTitle(for: try #require(onTime.events.first { $0.action == .taken })) == "Taken on time · snoozed 20 min")
    }

    @Test func snoozesAddUpAndARunningSnoozeIsExtendedFromItsEnd() throws {
        let (context, _, dose) = try morningDose()

        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 10), context: context)
        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 10, 5), context: context)
        #expect(dose.snoozedUntil == T.date(2026, 7, 13, 10, 40), "Two snoozes = forty minutes, not 10:25")
        #expect(dose.snoozeOffset == 40)

        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 11), context: context)
        #expect(dose.snoozedUntil == T.date(2026, 7, 13, 11, 20))
        #expect(dose.snoozeOffset == 60)
        #expect(dose.deadline == T.date(2026, 7, 13, 13))

        let snoozes = dose.events.filter { $0.action == .snoozed }.sorted { $0.loggedAt < $1.loggedAt }
        #expect(snoozes.map(\.snoozeMinutes) == [20, 20, 20])
        #expect(snoozes.map(\.snoozeOffsetMinutes) == [20, 40, 60])
        #expect(SnoozeWording.eventTitle(for: snoozes[0]) == "Snoozed 20 min")
        #expect(SnoozeWording.eventTitle(for: snoozes[2]) == "Snoozed 20 min · 1 hr in all")
    }

    @Test func snoozingAnOverdueDoseKeepsItOverdueOnceTheSnoozeEnds() throws {
        let (context, _, dose) = try morningDose()
        let evaluator = DoseStatusEvaluator()
        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 14), context: context)
        #expect(evaluator.effectiveStatus(for: dose, now: T.date(2026, 7, 13, 14, 10)) == .snoozed)
        #expect(evaluator.effectiveStatus(for: dose, now: T.date(2026, 7, 13, 14, 21)) == .overdue)
    }

    // MARK: Undo

    @Test func undoingASnoozeTakesItsMinutesBack() throws {
        let (context, medication, dose) = try morningDose()
        let evaluator = DoseStatusEvaluator()

        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 10), context: context)
        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 10, 5), context: context)
        try DoseRepository.applyAction(.pending, to: dose, now: T.date(2026, 7, 13, 10, 6), context: context)

        #expect(dose.snoozeOffset == 20)
        #expect(dose.snoozedUntil == T.date(2026, 7, 13, 10, 20), "Back to the first snooze's end")
        #expect(evaluator.effectiveStatus(for: dose, now: T.date(2026, 7, 13, 10, 10)) == .snoozed)
        #expect(dose.lastAction == .pending)
        let undo = try #require(dose.events.first { $0.action == .pending })
        #expect(undo.snoozeOffsetMinutes == 20)

        // Undoing a snooze whose time has passed: no snooze left, no offset left.
        let (context2, _, other) = try morningDose()
        try DoseRepository.applyAction(.snoozed, to: other, now: T.date(2026, 7, 13, 10), context: context2)
        try DoseRepository.applyAction(.pending, to: other, now: T.date(2026, 7, 13, 10, 30), context: context2)
        #expect(other.snoozeOffset == 0)
        #expect(other.snoozedUntil == nil)
        #expect(other.deadline == other.windowEnd)
        #expect(evaluator.effectiveStatus(for: other, now: T.date(2026, 7, 13, 12, 10)) == .overdue)
        _ = medication
    }

    @Test func undoingATakeKeepsTheEarlierSnooze() throws {
        let (context, _, dose) = try morningDose()
        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 10), context: context)
        try DoseRepository.applyAction(.taken, to: dose, now: T.date(2026, 7, 13, 10, 25), context: context)
        try DoseRepository.applyAction(.pending, to: dose, now: T.date(2026, 7, 13, 10, 26), context: context)

        #expect(dose.snoozeOffset == 20)
        #expect(dose.snoozedUntil == nil)
        #expect(dose.completedAt == nil)
        #expect(DoseStatusEvaluator().effectiveStatus(for: dose, now: T.date(2026, 7, 13, 12, 10)) == .due)
    }

    @Test func undoingASnoozeLoggedBeforeOffsetsEndsIt() throws {
        let (context, _, dose) = try morningDose()
        // What an older build wrote: a snooze with no minutes and no offset.
        dose.snoozedUntil = T.date(2026, 7, 13, 10, 20)
        dose.lastAction = .snoozed
        dose.status = .snoozed
        let legacy = DoseEvent(loggedAt: T.date(2026, 7, 13, 10), action: .snoozed, medication: dose.medication, scheduledDose: dose)
        dose.events.append(legacy)
        context.insert(legacy)
        try context.save()

        try DoseRepository.applyAction(.pending, to: dose, now: T.date(2026, 7, 13, 10, 5), context: context)
        #expect(dose.snoozedUntil == nil)
        #expect(dose.snoozeOffset == 0)
        #expect(SnoozeWording.eventTitle(for: legacy) == "Snoozed")
    }

    // MARK: Notifications

    @Test func theReminderFiresAtTheSnoozeEndAndNamesTheMovedDeadline() throws {
        let (context, _, dose) = try morningDose()
        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 10), context: context)

        let planned = NotificationPlanner.doseReminders(
            for: [dose], preferences: .default, evaluator: DoseStatusEvaluator(),
            now: T.date(2026, 7, 13, 10, 1), calendar: T.utc
        )
        let first = try #require(planned.first)
        #expect(first.fireDate == T.date(2026, 7, 13, 10, 20))
        #expect(planned.map(\.fireDate).dropFirst().first == T.date(2026, 7, 13, 10, 50), "Escalations follow the snooze end")

        let text = NotificationPlanner.content(for: dose, fireDate: first.fireDate, isFollowUp: false, localTimeZone: T.utc.timeZone)
        let deadline = ZonedTimeFormatter(home: T.utc.timeZone, local: T.utc.timeZone).time(T.date(2026, 7, 13, 12, 20))
        #expect(text.body == "Morning dose · snoozed 20 min · take by \(deadline).")

        let late = NotificationPlanner.content(for: dose, fireDate: T.date(2026, 7, 13, 12, 30), isFollowUp: true, localTimeZone: T.utc.timeZone)
        #expect(late.title == "Metformin is overdue")
        #expect(late.body == "Morning dose was due by \(deadline) (snoozed 20 min).")
    }

    // MARK: Old data

    @Test func rowsWithoutAnOffsetReadAsZero() throws {
        let context = try T.makeContext()
        let dose = ScheduledDose(
            occurrenceKey: "old", regimenVersion: 1, scheduledAt: T.date(2026, 7, 13, 6),
            timingLabel: "morning", reminderWindowMinutes: 60, graceWindowMinutes: 180,
            windowEndAt: T.date(2026, 7, 13, 12)
        )
        // A pre-upgrade snooze: until set, no offset recorded.
        dose.snoozedUntil = T.date(2026, 7, 13, 15)
        let event = DoseEvent(action: .taken, scheduledDose: dose)
        context.insert(dose)
        context.insert(event)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<ScheduledDose>()).first)
        #expect(fetched.snoozeOffsetMinutes == nil)
        #expect(fetched.snoozeOffset == 0)
        #expect(fetched.deadline == T.date(2026, 7, 13, 12))
        let evaluator = DoseStatusEvaluator()
        #expect(evaluator.effectiveStatus(for: fetched, now: T.date(2026, 7, 13, 14)) == .snoozed)
        #expect(evaluator.effectiveStatus(for: fetched, now: T.date(2026, 7, 13, 15, 30)) == .overdue)

        let fetchedEvent = try #require(try context.fetch(FetchDescriptor<DoseEvent>()).first)
        #expect(fetchedEvent.snoozeMinutes == nil && fetchedEvent.snoozeOffsetMinutes == nil && fetchedEvent.minutesLate == nil)
        #expect(SnoozeWording.eventTitle(for: fetchedEvent) == "Taken")

        // An old widget snapshot (no offset key) still decodes.
        let json = #"{"occurrenceKey":"k","displayName":"M","kindSymbol":"pills.fill","avatarHue":0,"takeWithFood":false,"timingLabel":"morning","scheduledAt":0,"windowEnd":3600,"isFlexibleWindow":true,"isTaken":false,"isSkipped":false,"storedStatus":"upcoming"}"#
        let item = try JSONDecoder().decode(WidgetDoseItem.self, from: Data(json.utf8))
        #expect(item.snoozeOffsetMinutes == nil)
        #expect(item.deadline == item.windowEnd)
    }

    // MARK: Widget, history, adherence

    @Test func theWidgetMirrorsTheOffset() throws {
        let (context, _, dose) = try morningDose()
        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 11, 50), context: context)
        let item = WidgetSnapshotWriter.makeItem(dose)
        #expect(item.snoozeOffsetMinutes == 20)
        let evaluator = DoseStatusEvaluator()
        for minute in [0, 10, 11, 20, 21, 60] {
            let now = T.date(2026, 7, 13, 12).addingTimeInterval(TimeInterval(minute * 60))
            #expect(item.resolvedStatus(now: now).rawValue == evaluator.effectiveStatus(for: dose, now: now).rawValue, "at 12:\(minute)")
        }
        #expect(normalized(item.timeText(localTimeZone: T.utc.timeZone)) == "by 12:20 PM")
    }

    @Test func wordingReadsCleanly() {
        #expect(SnoozeWording.duration(minutes: 20) == "20 min")
        #expect(SnoozeWording.duration(minutes: 65) == "1 hr 5 min")
        #expect(SnoozeWording.takenText(minutesLate: 45, snoozeMinutes: 30) == "Taken 45 min late · snoozed 30 min")
        #expect(SnoozeWording.takenText(minutesLate: 0, snoozeMinutes: 0) == "Taken on time")
        #expect(SnoozeWording.spoken("Taken 45 min late · snoozed 30 min") == "Taken 45 min late, snoozed 30 min")
    }

    @Test func historyAndExportNameTheSnooze() throws {
        let (context, medication, dose) = try morningDose()
        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 11, 50), context: context)
        try DoseRepository.applyAction(.taken, to: dose, now: T.date(2026, 7, 13, 12, 15), context: context)

        let csv = HistoryCSVExporter.csv(doseEvents: medication.doseEvents, refillEvents: [], timeZone: T.utc.timeZone)
        #expect(csv.contains("Taken 15 min late · snoozed 20 min"))
        #expect(csv.contains("Snoozed 20 min"))
        #expect(csv.contains("2026-07-13"))
    }

    @Test func adherenceReportsSnoozedDosesSeparately() throws {
        let context = try T.makeContext()
        let medication = try T.medication("Metformin", anchor: T.date(2026, 7, 13, 0), context: context)
        try T.refresh(context, at: T.date(2026, 7, 13, 7))
        let dose = try #require(T.doses(of: medication, onDayOf: T.date(2026, 7, 13)).first)
        try T.refresh(context, at: T.date(2026, 7, 15, 7))
        try DoseRepository.applyAction(.snoozed, to: dose, now: T.date(2026, 7, 13, 11, 50), context: context)
        try DoseRepository.applyAction(.taken, to: dose, now: T.date(2026, 7, 13, 12, 15), context: context)
        let next = try #require(T.doses(of: medication, onDayOf: T.date(2026, 7, 14)).first)
        try DoseRepository.applyAction(.taken, to: next, now: T.date(2026, 7, 14, 8), context: context)

        let evaluator = DoseStatusEvaluator()
        let stats = AdherenceStats.compute(
            doses: medication.scheduledDoses,
            statusFor: { evaluator.effectiveStatus(for: $0, now: T.date(2026, 7, 15, 13)) },
            now: T.date(2026, 7, 15, 13),
            calendar: T.utc
        )
        #expect(stats.takenCount == 2)
        #expect(stats.snoozedCount == 1)
        #expect(stats.lateCount == 1)
        // Snoozed-then-taken still counts as taken; the 15th's dose was missed.
        #expect(stats.missedCount == 1)
        #expect(stats.adherencePercent == 67)
    }
}
