import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// Display, Today, notification, widget, supply and search fixes from the 2026-10
/// health pass. Scheduling reconciliation lives in `ScheduleReconciliationTests`.
@MainActor
struct HealthPassBehaviourTests {
    private typealias T = TestSupport
    private let calendar = TestSupport.utc

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: Time labels

    @Test func clockTimeDisplaysItsOwnWallClockTime() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let time = ClockTime(hour: 9, minute: 2)
        #expect(normalized(time.displayText(calendar: newYork, locale: Locale(identifier: "en_US"))) == "9:02 AM")
        let german = time.displayText(calendar: newYork, locale: Locale(identifier: "de_DE"))
        #expect(german.contains("9:02") && !german.contains("AM"))

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(normalized(ClockTime(hour: 21, minute: 30).displayText(calendar: tokyo, locale: Locale(identifier: "en_US"))) == "9:30 PM")
    }

    @Test func slotLabelsAreStableAndDisplayCleanly() {
        #expect(DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 9, minute: 2)).slotLabel == "at-0902")
        #expect(DailyTiming(kind: .bedtime).slotLabel == "before-bed")
        #expect(SlotTitle.title(label: "before-bed") == "Before bed")
        #expect(SlotTitle.title(label: "morning") == "Morning")
        #expect(normalized(SlotTitle.title(label: "at-0902")).contains("9:02"))

        // A legacy exact-time row shows its real time, not "4:02 Am".
        let legacy = ScheduledDose(
            occurrenceKey: "k", regimenVersion: 1, scheduledAt: T.date(2026, 7, 13, 9, 2),
            timingLabel: "4:02-am", reminderWindowMinutes: 60, graceWindowMinutes: 180
        )
        #expect(legacy.slotTitle == T.date(2026, 7, 13, 9, 2).formatted(date: .omitted, time: .shortened))
    }

    @Test func undoReadsAsUndoneInTheExport() {
        let medication = Medication(displayName: "Med")
        let event = DoseEvent(loggedAt: T.date(2026, 7, 13), action: .pending, medication: medication)
        let csv = HistoryCSVExporter.csv(doseEvents: [event], refillEvents: [])
        #expect(csv.contains(",Undone,"))
        #expect(!csv.contains("Pending"))
    }

    @Test func weeklyScheduleWithoutWeekdaysNamesTheStartDay() {
        let regimen = MedicationRegimen(
            anchorDate: T.date(2026, 7, 14),  // a Tuesday
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: []),
            timings: [DailyTiming(kind: .morning)]
        )
        #expect(AppFormatting.scheduleText(for: regimen).contains("Tuesday"))
    }

    @Test func supplyUnitsAgreeWithTheCount() {
        #expect(SupplyRow.unit("doses", count: 1) == "dose")
        #expect(SupplyRow.unit("tablets", count: 2) == "tablets")
        #expect(SupplyRow.unit("ml", count: 1) == "ml")
    }

    // MARK: Today

    private func dose(_ medication: Medication, at start: Date, end: Date) -> ScheduledDose {
        let dose = ScheduledDose(
            occurrenceKey: UUID().uuidString, regimenVersion: 1, scheduledAt: start,
            timingLabel: "morning", reminderWindowMinutes: 60, graceWindowMinutes: 60,
            windowEndAt: end, medication: medication
        )
        return dose
    }

    @Test func yesterdaysMissedDoseLeavesTodayOnceTodaysDoseIsDue() {
        let medication = Medication(displayName: "Daily")
        let now = T.date(2026, 7, 13, 10)
        let yesterday = dose(medication, at: T.date(2026, 7, 12, 6), end: T.date(2026, 7, 12, 12))
        let today = dose(medication, at: T.date(2026, 7, 13, 6), end: T.date(2026, 7, 13, 12))
        let evaluator = DoseStatusEvaluator()

        let buckets = TodayBucketing.bucket(
            doses: [yesterday, today],
            statusFor: { evaluator.effectiveStatus(for: $0, now: now) },
            now: now, calendar: calendar
        )
        #expect(buckets.overdue.isEmpty)
        #expect(buckets.takeNow.map(\.id) == [today.id])
        // Still a miss for the record.
        #expect(evaluator.effectiveStatus(for: yesterday, now: now) == .overdue)
    }

    @Test func todaysMissedDoseStaysOverdueAfterTheNextOneOpens() {
        let medication = Medication(displayName: "Twice")
        let now = T.date(2026, 7, 13, 15)
        let morning = dose(medication, at: T.date(2026, 7, 13, 6), end: T.date(2026, 7, 13, 12))
        let afternoon = dose(medication, at: T.date(2026, 7, 13, 14), end: T.date(2026, 7, 13, 17))
        let evaluator = DoseStatusEvaluator()

        let buckets = TodayBucketing.bucket(
            doses: [morning, afternoon],
            statusFor: { evaluator.effectiveStatus(for: $0, now: now) },
            now: now, calendar: calendar
        )
        #expect(buckets.overdue.map(\.id) == [morning.id])
        #expect(buckets.takeNow.map(\.id) == [afternoon.id])
    }

    @Test func archivedMedicationsRowsNeverReachToday() {
        let archived = Medication(displayName: "Old", isActive: false)
        let now = T.date(2026, 7, 13, 10)
        let completed = dose(archived, at: T.date(2026, 7, 13, 6), end: T.date(2026, 7, 13, 12))
        completed.lastAction = .taken
        completed.status = .takenOnTime
        completed.completedAt = T.date(2026, 7, 13, 7)

        let buckets = TodayBucketing.bucket(
            doses: [completed],
            statusFor: { DoseStatusEvaluator().effectiveStatus(for: $0, now: now) },
            now: now, calendar: calendar
        )
        #expect(buckets.completed.isEmpty)
    }

    // MARK: Notifications

    @Test func overdueDosesKeepTheirLaterEscalations() {
        let medication = Medication(displayName: "Lisinopril")
        let exact = ScheduledDose(
            occurrenceKey: "exact", regimenVersion: 1, scheduledAt: T.date(2026, 7, 13, 8),
            timingLabel: "at-0800", reminderWindowMinutes: 60, graceWindowMinutes: 60,
            reminderAt: T.date(2026, 7, 13, 8), medication: medication
        )
        let now = T.date(2026, 7, 13, 9, 30)  // grace ended at 9:00
        let planned = NotificationPlanner.doseReminders(
            for: [exact], preferences: .default, evaluator: DoseStatusEvaluator(), now: now, calendar: calendar
        )
        // Default escalations 0, 30, 120, 720, 1440 → 10:00, 20:00, tomorrow 8:00 are still ahead.
        #expect(planned.map(\.fireDate) == [T.date(2026, 7, 13, 10), T.date(2026, 7, 13, 20), T.date(2026, 7, 14, 8)])
        #expect(planned.allSatisfy { $0.title == "Lisinopril is overdue" })
    }

    @Test func reminderTextNamesTheSlotAndDeadline() {
        let medication = Medication(displayName: "Metformin", takeWithFood: true)
        let morning = ScheduledDose(
            occurrenceKey: "m", regimenVersion: 1, scheduledAt: T.date(2026, 7, 13, 6),
            timingLabel: "morning", reminderWindowMinutes: 60, graceWindowMinutes: 180,
            windowEndAt: T.date(2026, 7, 13, 12), reminderAt: T.date(2026, 7, 13, 11), medication: medication
        )
        let text = NotificationPlanner.content(for: morning, fireDate: T.date(2026, 7, 13, 11), isFollowUp: false)
        let end = T.date(2026, 7, 13, 12).formatted(date: .omitted, time: .shortened)
        #expect(text.title == "Time for Metformin")
        #expect(text.body == "Morning dose · take by \(end). Take with food.")
    }

    @Test func budgetKeepsRefillRemindersAndTheSoonestDoses() {
        func planned(_ id: String, _ hours: Int) -> NotificationPlanner.Planned {
            NotificationPlanner.Planned(
                identifier: id, fireDate: T.date(2026, 7, 13).addingTimeInterval(TimeInterval(hours * 3600)),
                title: "", body: "", timeSensitive: false, playSound: true,
                categoryIdentifier: nil, occurrenceKey: nil, medicationID: nil
            )
        }
        let doses = (0..<200).map { planned("dose-\($0)", $0) }
        let refill = planned("refill-a", 24 * 40)
        let plan = NotificationPlanner.budgeted(doseReminders: doses, refillReminders: [refill])

        #expect(plan.count == NotificationPlanner.systemLimit)
        #expect(plan.contains { $0.identifier == "refill-a" })
        #expect(plan.filter { $0.identifier.hasPrefix("dose-") }.map(\.identifier) == (0..<63).map { "dose-\($0)" })
    }

    @Test func snoozeIsLeftOffWhenTheMedicationDisallowsIt() {
        let medication = Medication(displayName: "No Snooze")
        let regimen = MedicationRegimen(anchorDate: T.date(2026, 7, 1), medication: medication)
        let policy = ReminderPolicy(allowSnooze: false)
        regimen.reminderPolicies = [policy]
        medication.regimens = [regimen]
        let due = ScheduledDose(
            occurrenceKey: "d", regimenVersion: 1, scheduledAt: T.date(2026, 7, 13, 6),
            timingLabel: "morning", reminderWindowMinutes: 60, graceWindowMinutes: 180,
            windowEndAt: T.date(2026, 7, 13, 12), reminderAt: T.date(2026, 7, 13, 11), medication: medication
        )
        let planned = NotificationPlanner.doseReminders(
            for: [due], preferences: .default, evaluator: DoseStatusEvaluator(), now: T.date(2026, 7, 13, 9), calendar: calendar
        )
        #expect(!planned.isEmpty)
        #expect(planned.allSatisfy { $0.categoryIdentifier == NotificationActionHandler.Identifier.doseCategoryNoSnooze })
        #expect(!DoseActions.canSnooze(due, status: .due))
        #expect(!DoseActions.canSnooze(due, status: .upcoming))
    }

    // MARK: Supply

    @Test func aDoseAlreadyTakenTodayIsNotCountedTwice() throws {
        let context = try T.makeContext()
        let medication = try T.medication(anchor: T.date(2026, 7, 1), context: context)
        medication.supplyUnitLabel = "tablets"
        medication.unitsPerContainer = 30
        medication.supplyContainers = [5]
        try T.refresh(context, at: T.date(2026, 7, 16, 5))

        let before = SupplyForecastService.projection(
            for: medication, engine: DoseScheduleEngine(deviceClock: .atHome), preferences: .default,
            now: T.date(2026, 7, 16, 5), calendar: calendar
        )
        #expect(before.map { calendar.component(.day, from: $0.runOutDate) } == 20)

        let today = try #require(T.doses(of: medication, onDayOf: T.date(2026, 7, 16)).first)
        try DoseRepository.applyAction(.taken, to: today, now: T.date(2026, 7, 16, 7), context: context)

        // 4 left after this morning's dose → Jul 17…20, still Jul 20.
        let after = SupplyForecastService.projection(
            for: medication, engine: DoseScheduleEngine(deviceClock: .atHome), preferences: .default,
            now: T.date(2026, 7, 16, 8), calendar: calendar
        )
        #expect(after.map { calendar.component(.day, from: $0.runOutDate) } == 20)
    }

    // MARK: Widget

    private func item(_ key: String, medication: String, start: Date, end: Date) -> WidgetDoseItem {
        WidgetDoseItem(
            occurrenceKey: key, medicationID: medication, displayName: medication, kindSymbol: "pills.fill",
            avatarHue: 0, takeWithFood: false, timingLabel: "morning",
            scheduledAt: start, windowEnd: end, isFlexibleWindow: true, snoozedUntil: nil,
            isTaken: false, isSkipped: false, storedStatus: "upcoming"
        )
    }

    @Test func widgetShowsTomorrowsDosesOnlyOnceTomorrowComes() {
        let today = item("today", medication: "A", start: T.date(2026, 7, 13, 6), end: T.date(2026, 7, 13, 12))
        let tomorrow = item("tomorrow", medication: "A", start: T.date(2026, 7, 14, 6), end: T.date(2026, 7, 14, 12))
        let snapshot = TodayWidgetSnapshot(generatedAt: T.date(2026, 7, 13, 9), showMedicationNames: true, items: [today, tomorrow])

        #expect(snapshot.items(relevantAt: T.date(2026, 7, 13, 9), calendar: calendar).map(\.occurrenceKey) == ["today"])
        // After midnight the new day's dose replaces yesterday's miss.
        #expect(snapshot.items(relevantAt: T.date(2026, 7, 14, 0, 30), calendar: calendar).map(\.occurrenceKey) == ["tomorrow"])
        #expect(snapshot.items(relevantAt: T.date(2026, 7, 14, 7), calendar: calendar).map(\.occurrenceKey) == ["tomorrow"])

        // A medication with nothing today keeps yesterday's miss on the widget.
        let weekly = item("weekly", medication: "B", start: T.date(2026, 7, 13, 6), end: T.date(2026, 7, 13, 12))
        let weeklySnapshot = TodayWidgetSnapshot(generatedAt: T.date(2026, 7, 13, 9), showMedicationNames: true, items: [weekly])
        #expect(weeklySnapshot.items(relevantAt: T.date(2026, 7, 14, 9), calendar: calendar).map(\.occurrenceKey) == ["weekly"])
    }

    @Test func widgetSnapshotCarriesTomorrow() throws {
        let context = try T.makeContext()
        let cal = Calendar.current
        let base = cal.startOfDay(for: .now)
        let medication = Medication(displayName: "Daily")
        context.insert(medication)
        let tomorrowDose = ScheduledDose(
            occurrenceKey: "tomorrow", regimenVersion: 1,
            scheduledAt: cal.date(byAdding: .hour, value: 24 + 8, to: base)!,
            timingLabel: "morning", reminderWindowMinutes: 60, graceWindowMinutes: 60,
            windowEndAt: cal.date(byAdding: .hour, value: 24 + 10, to: base)!, medication: medication
        )
        context.insert(tomorrowDose)
        try context.save()

        let snapshot = WidgetSnapshotWriter.buildSnapshot(
            context: context, evaluator: DoseStatusEvaluator(), preferences: .default,
            now: cal.date(byAdding: .hour, value: 12, to: base)!
        )
        #expect(snapshot.items.map(\.occurrenceKey) == ["tomorrow"])
        #expect(snapshot.items.first?.medicationID == medication.id.uuidString)
    }

    // MARK: Lookup

    private func searchModel() -> MedicationSearchModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return MedicationSearchModel(lookupService: MedicationLookupService(urlSession: URLSession(configuration: configuration)))
    }

    @Test func searchReportsMatchesNoMatchesAndFailures() async {
        let model = searchModel()
        model.query = "furosemide"
        await model.search(debounce: .zero)
        #expect(model.results.count == 2)
        #expect(model.errorMessage == nil)

        model.query = "zzz"
        await model.search(debounce: .zero)
        #expect(model.results.isEmpty)
        #expect(model.errorMessage?.hasPrefix("No matches") == true)

        model.query = "offline"
        await model.search(debounce: .zero)
        #expect(model.errorMessage?.hasPrefix("Search is unavailable") == true)
    }

    @Test func aCancelledSearchLeavesNoError() async {
        let model = searchModel()
        model.query = "furosemide"
        let task = Task { await model.search(debounce: .milliseconds(300)) }
        task.cancel()
        await task.value
        #expect(model.errorMessage == nil)
        #expect(model.isSearching == false)
    }

    // MARK: Editing

    @Test func onlyScheduleChangesCreateANewRegimenVersion() {
        let medication = Medication(displayName: "Med")
        let regimen = MedicationRegimen(
            anchorDate: T.date(2026, 7, 1),
            recurrenceRule: RecurrenceRule(frequency: .daily),
            timings: [DailyTiming(kind: .morning)],
            medication: medication
        )
        let policy = ReminderPolicy()
        regimen.reminderPolicies = [policy]
        medication.regimens = [regimen]

        var draft = MedicationDraft(medication: medication)
        #expect(!draft.scheduleDiffers(from: regimen))
        #expect(!draft.reminderPolicyDiffers(from: policy))

        draft.notes = "Take after breakfast"
        draft.displayName = "Renamed"
        #expect(!draft.scheduleDiffers(from: regimen))

        draft.allowSnooze = false
        #expect(draft.reminderPolicyDiffers(from: policy))
        #expect(!draft.scheduleDiffers(from: regimen))

        draft.timings.append(DailyTiming(kind: .evening))
        #expect(draft.scheduleDiffers(from: regimen))
    }
}
