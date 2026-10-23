import Foundation

/// Adherence summary computed from persisted `ScheduledDose` rows — pure static logic
/// (status injected as a closure), same testable shape as `TodayBucketing`.
enum AdherenceStats {
    static let windowDays = 30

    struct Stats: Equatable {
        /// Percent of past-window doses that were taken (on time or late). nil when the
        /// window holds no concluded doses yet.
        var adherencePercent: Int?
        var takenCount: Int = 0
        var missedCount: Int = 0
        /// Consecutive days ending today (or yesterday, if today has no concluded doses
        /// yet) where every concluded dose was taken.
        var currentStreakDays: Int = 0
        /// The timing label ("morning", "evening", …) with the most missed doses.
        var mostMissedSlot: String?
    }

    static func compute(
        doses: [ScheduledDose],
        statusFor: (ScheduledDose) -> DoseStatus,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Stats {
        guard let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: now) else { return Stats() }

        var stats = Stats()
        var missesBySlot: [String: Int] = [:]
        // day → (allTaken, anyConcluded) for the streak walk.
        var dayOutcomes: [Date: (taken: Int, missed: Int)] = [:]

        for dose in doses {
            guard dose.scheduledAt >= windowStart, dose.scheduledAt <= now else { continue }

            // Only doses whose outcome is settled: taken, skipped, or past their window.
            let taken: Bool
            switch statusFor(dose) {
            case .takenOnTime, .takenLate:
                taken = true
            case .skipped, .overdue:
                taken = false
            case .upcoming, .due, .snoozed:
                continue  // still in play — not evidence either way
            }

            let day = calendar.startOfDay(for: dose.scheduledAt)
            if taken {
                stats.takenCount += 1
                dayOutcomes[day, default: (0, 0)].taken += 1
            } else {
                stats.missedCount += 1
                missesBySlot[dose.timingLabel, default: 0] += 1
                dayOutcomes[day, default: (0, 0)].missed += 1
            }
        }

        let concluded = stats.takenCount + stats.missedCount
        if concluded > 0 {
            stats.adherencePercent = Int((Double(stats.takenCount) / Double(concluded) * 100).rounded())
        }
        stats.mostMissedSlot = missesBySlot.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key

        // Streak: consecutive *dosing days* fully taken, walking back from today. Days
        // with nothing scheduled (a weekly med's off-days) are neutral — they neither
        // extend nor break the streak. Any day with a miss ends it.
        var streak = 0
        var day = calendar.startOfDay(for: now)
        for _ in 0..<windowDays {
            if let outcome = dayOutcomes[day] {
                if outcome.missed > 0 { break }
                streak += 1
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        stats.currentStreakDays = streak

        return stats
    }
}
