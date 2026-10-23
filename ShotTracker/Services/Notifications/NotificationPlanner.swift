import Foundation

/// What `NotificationScheduler` should have pending, computed as plain values so the
/// rules are unit-testable without `UNUserNotificationCenter`.
///
/// iOS keeps at most 64 pending local notifications per app and silently drops the rest,
/// so the plan is budgeted: refill reminders first (one per medication, rare and easy to
/// lose), then the soonest dose reminders until the budget is spent. The app re-plans on
/// every launch, foreground and dose action, so the window keeps moving forward.
enum NotificationPlanner {
    /// iOS's pending-notification limit.
    static let systemLimit = 64

    struct Planned: Equatable {
        let identifier: String
        let fireDate: Date
        let title: String
        let body: String
        let timeSensitive: Bool
        let playSound: Bool
        let categoryIdentifier: String?
        let occurrenceKey: String?
        let medicationID: String?
    }

    /// Dose reminders for every dose that can still use one: upcoming, due, snoozed, and
    /// overdue (an overdue dose keeps its later escalations — they used to be dropped by
    /// any reschedule that happened after the window closed). Doses a later dose of the
    /// same medication has replaced get nothing.
    static func doseReminders(
        for doses: [ScheduledDose],
        preferences: AppPreferences,
        evaluator: DoseStatusEvaluator,
        now: Date,
        calendar: Calendar = .current
    ) -> [Planned] {
        guard preferences.globalNotificationsEnabled else { return [] }
        let superseded = DoseSupersession.supersededIDs(in: doses, now: now, calendar: calendar)

        var planned: [Planned] = []
        for dose in doses where !superseded.contains(dose.id) {
            if dose.medication?.isActive == false { continue }
            let status = evaluator.effectiveStatus(for: dose, now: now)
            guard status == .upcoming || status == .due || status == .snoozed || status == .overdue else { continue }

            let policy = dose.medication?.regimens.active?.activeReminderPolicy ?? ReminderPolicy()
            let timeSensitive = dose.medication?.timeSensitiveNotifications ?? preferences.timeSensitiveByDefault
            let allowsSnooze = DoseActions.allowsSnooze(dose.medication)

            for (index, fireDate) in fireDates(for: dose, policy: policy, preferences: preferences).enumerated()
            where fireDate > now {
                let text = content(for: dose, fireDate: fireDate, isFollowUp: index > 0)
                planned.append(Planned(
                    identifier: "\(dose.occurrenceKey)-\(index)",
                    fireDate: fireDate,
                    title: text.title,
                    body: text.body,
                    timeSensitive: timeSensitive,
                    playSound: policy.playSound,
                    categoryIdentifier: allowsSnooze
                        ? NotificationActionHandler.Identifier.doseCategory
                        : NotificationActionHandler.Identifier.doseCategoryNoSnooze,
                    occurrenceKey: dose.occurrenceKey,
                    medicationID: dose.medication?.id.uuidString
                ))
            }
        }
        return planned
    }

    /// Refill reminders first, then the soonest dose reminders, within `limit`.
    static func budgeted(doseReminders: [Planned], refillReminders: [Planned], limit: Int = systemLimit) -> [Planned] {
        let refills = Array(refillReminders.sorted { $0.fireDate < $1.fireDate }.prefix(limit))
        let doses = doseReminders
            .sorted { $0.fireDate == $1.fireDate ? $0.identifier < $1.identifier : $0.fireDate < $1.fireDate }
            .prefix(max(0, limit - refills.count))
        return (refills + doses).sorted { $0.fireDate < $1.fireDate }
    }

    static func fireDates(for dose: ScheduledDose, policy: ReminderPolicy, preferences: AppPreferences) -> [Date] {
        guard policy.isEnabled, preferences.globalNotificationsEnabled else { return [] }

        var intervals = policy.escalationIntervalsMinutes
        if !preferences.globalDueRemindersEnabled || !policy.dueRemindersEnabled {
            intervals.removeAll(where: { $0 == 0 })
        }
        if !preferences.globalOverdueRemindersEnabled || !policy.overdueRemindersEnabled {
            intervals = intervals.filter { $0 == 0 }
        }

        // Base the nudge on the reminder instant (near a window's close) rather than the
        // window start, so a flexible dose doesn't ping the moment its window opens. A
        // snoozed dose reminds when its snooze ends.
        let baseDate = dose.snoozedUntil ?? dose.reminderAt ?? dose.scheduledAt
        return intervals.prefix(policy.maxReminderCount).map { minutes in
            baseDate.addingTimeInterval(TimeInterval(minutes * 60))
        }
    }

    /// "Time for Metformin" / "Morning dose · take by 12:00 PM." — the old body read
    /// "Metformin is due morning." (and "is due 4:02 am." for a 9:02 dose).
    ///
    /// Times read in the dose's home time zone and, when the device is somewhere else,
    /// in both: "take by 12:00 PM home · 6:00 PM here." A snoozed dose says so and uses
    /// its moved deadline: "Morning dose · snoozed 20 min · take by 12:20 PM."
    static func content(
        for dose: ScheduledDose,
        fireDate: Date,
        isFollowUp: Bool,
        localTimeZone: TimeZone = .current
    ) -> (title: String, body: String) {
        let name = dose.medication?.displayName ?? "Medication"
        let deadline = dose.deadline
        let isOverdue = fireDate > deadline
        let times = ZonedTimeFormatter(home: dose.homeTimeZone, local: localTimeZone)

        let title: String
        if isOverdue {
            title = "\(name) is overdue"
        } else if isFollowUp {
            title = "\(name) not logged yet"
        } else {
            title = "Time for \(name)"
        }

        let snooze = dose.snoozeOffset > 0 ? "snoozed \(SnoozeWording.duration(minutes: dose.snoozeOffset))" : nil
        var body: String
        if dose.isFlexibleWindow {
            let end = times.time(deadline)
            if isOverdue {
                body = "\(dose.slotTitle) dose was due by \(end)" + (snooze.map { " (\($0))" } ?? "") + "."
            } else {
                body = "\(dose.slotTitle) dose" + (snooze.map { " · \($0)" } ?? "") + " · take by \(end)."
            }
        } else {
            let time = times.time(dose.scheduledAt)
            if isOverdue {
                body = "Dose was due at \(time)" + (snooze.map { " (\($0))" } ?? "") + "."
            } else {
                body = "Dose due at \(time)" + (snooze.map { " · \($0)" } ?? "") + "."
            }
        }
        if dose.medication?.takeWithFood == true {
            body += " Take with food."
        }
        return (title, body)
    }
}
