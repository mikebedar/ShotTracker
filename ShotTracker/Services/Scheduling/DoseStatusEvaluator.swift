import Foundation

final class DoseStatusEvaluator {
    func effectiveStatus(for dose: ScheduledDose, now: Date = .now) -> DoseStatus {
        if dose.lastAction == .skipped {
            return .skipped
        }

        if dose.lastAction == .taken {
            return dose.status
        }

        if let snoozedUntil = dose.snoozedUntil, snoozedUntil > now {
            return .snoozed
        }

        if now < dose.windowStart {
            return .upcoming
        }

        // A snooze moves only the deadline, by the snoozed minutes (it used to push both
        // window bounds to the snooze end, stretching a morning dose into the afternoon).
        if now <= dose.deadline {
            return .due
        }

        return .overdue
    }

    /// On time vs late is judged against the *original* window: a snooze buys time
    /// before the dose counts as overdue, not a later "on time".
    func completionStatus(for dose: ScheduledDose, completionDate: Date) -> DoseStatus {
        // Anywhere up to the window close — including early — counts as on time.
        completionDate <= dose.windowEnd ? .takenOnTime : .takenLate
    }

    func statusSummary(for dose: ScheduledDose, medicationName: String, now: Date = .now) -> String {
        let status = effectiveStatus(for: dose, now: now)
        let time = ZonedTimeFormatter(home: dose.homeTimeZone).spokenTime(dose.scheduledAt)
        return "\(medicationName), \(status.title), scheduled \(time)"
    }
}

/// Which actions a dose offers right now — shared by Today, a medication's scheduled
/// list and the notification categories so they never disagree.
enum DoseActions {
    /// Snooze only means something once a dose is due: snoozing an upcoming dose would
    /// make the snooze end its new window start, pulling the dose *earlier*. A
    /// medication whose reminder policy turns snooze off never offers it.
    static func canSnooze(_ dose: ScheduledDose, status: DoseStatus) -> Bool {
        guard status == .due || status == .overdue || status == .snoozed else { return false }
        return allowsSnooze(dose.medication)
    }

    static func allowsSnooze(_ medication: Medication?) -> Bool {
        medication?.regimens.active?.activeReminderPolicy?.allowSnooze ?? true
    }
}
