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

        // A snooze pushes both bounds of the (possibly flexible) window forward.
        let windowStart = dose.snoozedUntil ?? dose.windowStart
        let windowEnd = dose.snoozedUntil.map { $0.addingTimeInterval(dose.windowEnd.timeIntervalSince(dose.windowStart)) } ?? dose.windowEnd

        if now < windowStart {
            return .upcoming
        }

        if now <= windowEnd {
            return .due
        }

        return .overdue
    }

    func completionStatus(for dose: ScheduledDose, completionDate: Date) -> DoseStatus {
        let windowEnd = dose.snoozedUntil.map { $0.addingTimeInterval(dose.windowEnd.timeIntervalSince(dose.windowStart)) } ?? dose.windowEnd
        // Anywhere up to the window close — including early — counts as on time.
        return completionDate <= windowEnd ? .takenOnTime : .takenLate
    }

    func statusSummary(for dose: ScheduledDose, medicationName: String, now: Date = .now) -> String {
        let status = effectiveStatus(for: dose, now: now)
        let time = dose.scheduledAt.formatted(date: .omitted, time: .shortened)
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
