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
