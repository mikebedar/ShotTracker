#if DEBUG
import Foundation
import SwiftData

/// Demo content for `-seedDemoData` launches (screenshots, manual walkthroughs, UI
/// tests): one medication per regimen kind, today's doses spread over every Today
/// bucket relative to the launch time, and a week of history. Only seeds an empty store.
@MainActor
enum DemoData {
    static func seedIfEmpty(in context: ModelContext, now: Date = .now) {
        let existing = (try? context.fetchCount(FetchDescriptor<Medication>())) ?? 0
        guard existing == 0 else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -10, to: today) ?? today
        let minutesNow = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        func clock(_ offsetMinutes: Int) -> ClockTime {
            let total = min(max(0, minutesNow + offsetMinutes), 23 * 60 + 59)
            return ClockTime(hour: total / 60, minute: total % 60)
        }
        let weekday = calendar.component(.weekday, from: now)
        let dayOfMonth = calendar.component(.day, from: now)

        // Overdue: a precise dose two hours ago with a one-hour grace.
        add("Lisinopril", canonical: "lisinopril 10 mg", kind: .oral,
            rule: RecurrenceRule(frequency: .daily),
            timings: [DailyTiming(kind: .exactTime, exactTime: clock(-120))], grace: 60,
            supply: (perContainer: 90, onHand: 7, unit: "tablets"), withFood: false,
            anchor: weekAgo, in: context)

        // Take now: a window open around the launch time; twice daily with food.
        add("Metformin", canonical: "metformin 500 mg", kind: .oral,
            rule: RecurrenceRule(frequency: .daily),
            timings: [
                DailyTiming(kind: .morning, customWindow: DoseWindow(start: clock(-60), end: clock(120))),
                DailyTiming(kind: .bedtime),
            ],
            supply: (perContainer: 60, onHand: 41, unit: "tablets"), withFood: true,
            anchor: weekAgo, in: context)

        // Coming up soon / later today: every other day, an hour from now.
        add("Vitamin D", canonical: nil, kind: .oral,
            rule: RecurrenceRule(frequency: .intervalDays, intervalDays: 2),
            timings: [DailyTiming(kind: .exactTime, exactTime: clock(60))],
            anchor: today, in: context)

        // Weekly injection on today's weekday, rescheduled from the last dose.
        add("Ozempic", canonical: "semaglutide", kind: .injection,
            rule: RecurrenceRule(frequency: .weekly, weekdays: [weekday]),
            timings: [DailyTiming(kind: .evening)],
            supply: (perContainer: 4, onHand: 2, unit: "doses"),
            policy: .rescheduleFromLastDose, anchor: weekAgo, in: context)

        // Monthly on today's date.
        add("Vitamin B12", canonical: "cyanocobalamin", kind: .injection,
            rule: RecurrenceRule(frequency: .monthly, dayOfMonth: dayOfMonth),
            timings: [DailyTiming(kind: .noon)], anchor: weekAgo, in: context)

        // 21 days on, 7 off, at night.
        add("Letrozole", canonical: nil, kind: .oral,
            rule: RecurrenceRule(frequency: .cycle, cycleOnDays: 21, cycleOffDays: 7),
            timings: [DailyTiming(kind: .night)], anchor: weekAgo, in: context)

        // A taper: twice a day for five days, daily for five, then every other day.
        let taper = add("Prednisone", canonical: "prednisone 10 mg", kind: .oral,
            rule: RecurrenceRule(frequency: .phased),
            timings: [DailyTiming(kind: .morning)], anchor: calendar.date(byAdding: .day, value: -3, to: today) ?? today,
            in: context)
        if let regimen = taper.regimens.first {
            for phase in [
                RegimenPhase(title: "Loading", startDayOffset: 0, durationDays: 5, recurrenceRule: RecurrenceRule(frequency: .daily), timings: []),
                RegimenPhase(title: "Taper", startDayOffset: 5, durationDays: 5, recurrenceRule: RecurrenceRule(frequency: .daily), timings: []),
                RegimenPhase(title: "Maintenance", startDayOffset: 10, durationDays: nil, recurrenceRule: RecurrenceRule(frequency: .intervalDays, intervalDays: 2), timings: []),
            ] {
                phase.regimen = regimen
                regimen.phases.append(phase)
                context.insert(phase)
            }
        }

        try? context.save()

        // Materialize, then log a believable past week: mostly taken, a skip, a miss.
        try? DoseRepository.refreshSchedules(in: context, engine: DoseScheduleEngine(), preferences: AppPreferencesStore.shared.preferences, referenceDate: now)
        let doses = (try? context.fetch(FetchDescriptor<ScheduledDose>(sortBy: [SortDescriptor(\.scheduledAt)]))) ?? []
        for (index, dose) in doses.enumerated() where dose.scheduledAt < today {
            if index % 9 == 4 { continue }  // missed
            let action: DoseActionType = index % 11 == 7 ? .skipped : .taken
            try? DoseRepository.applyAction(action, to: dose, now: dose.scheduledAt.addingTimeInterval(20 * 60), context: context)
        }
        // Today: Vitamin B12 already taken, so Completed has something in it.
        if let b12 = doses.first(where: { $0.medication?.displayName == "Vitamin B12" && calendar.isDate($0.scheduledAt, inSameDayAs: now) }) {
            try? DoseRepository.applyAction(.taken, to: b12, now: now, context: context)
        }
        if let lisinopril = (try? context.fetch(FetchDescriptor<Medication>()))?.first(where: { $0.displayName == "Lisinopril" }) {
            try? MedicationRepository.logRefill(90, for: lisinopril, now: calendar.date(byAdding: .day, value: -30, to: now) ?? now, in: context)
            lisinopril.supplyContainers = [7]
        }
        try? context.save()
    }

    @discardableResult
    private static func add(
        _ name: String,
        canonical: String?,
        kind: MedicationKind,
        rule: RecurrenceRule,
        timings: [DailyTiming],
        grace: Int = 180,
        supply: (perContainer: Int, onHand: Int, unit: String)? = nil,
        withFood: Bool = false,
        policy: MissedDosePolicy? = nil,
        anchor: Date,
        in context: ModelContext
    ) -> Medication {
        let medication = Medication(
            displayName: name,
            canonicalName: canonical,
            createdAt: anchor,
            kind: kind,
            takeWithFood: withFood,
            unitsPerContainer: supply?.perContainer,
            supplyContainers: supply.map { [$0.onHand] },
            supplyUnitLabel: supply?.unit,
            supplyLowThreshold: supply.map { max(1, $0.perContainer / 5) }
        )
        let regimen = MedicationRegimen(
            anchorDate: anchor,
            recurrenceRule: rule,
            timings: timings,
            graceWindowMinutes: grace,
            createdAt: anchor,
            missedDosePolicy: policy ?? MissedDosePolicy.defaultFor(kind: kind),
            medication: medication
        )
        let reminders = ReminderPolicy()
        reminders.regimen = regimen
        regimen.reminderPolicies.append(reminders)
        medication.regimens.append(regimen)
        context.insert(medication)
        context.insert(regimen)
        context.insert(reminders)
        return medication
    }
}
#endif
