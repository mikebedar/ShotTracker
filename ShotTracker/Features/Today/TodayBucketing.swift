import Foundation

/// Today's doses grouped into time-based buckets for the list layout.
struct TodayBuckets {
    var overdue: [ScheduledDose] = []
    var takeNow: [ScheduledDose] = []
    var comingUpSoon: [ScheduledDose] = []
    var laterToday: [ScheduledDose] = []
    var tonight: [ScheduledDose] = []
    var completed: [ScheduledDose] = []
}

/// Pure bucketing logic for the Today screen, independent of `AppDependencies` so
/// it's directly unit-testable. `statusFor` is injected because the "effective"
/// status of a dose depends on the current time (`DoseStatusEvaluator`), not just
/// its stored state.
enum TodayBucketing {
    static let soonWindow: TimeInterval = 3 * 60 * 60
    static let tonightHour = 18

    static func bucket(
        doses: [ScheduledDose],
        statusFor: (ScheduledDose) -> DoseStatus,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TodayBuckets {
        var buckets = TodayBuckets()

        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return buckets }
        let tonightStart = calendar.date(bySettingHour: tonightHour, minute: 0, second: 0, of: startOfToday) ?? startOfToday

        for dose in doses {
            guard dose.scheduledAt < startOfTomorrow else { continue }

            switch statusFor(dose) {
            case .overdue:
                // No lower date bound: a dose missed on an earlier day is still
                // overdue today and needs attention.
                buckets.overdue.append(dose)
            case .due:
                buckets.takeNow.append(dose)
            case .takenOnTime, .takenLate, .skipped:
                // Only doses scheduled for today — a completion from a prior day
                // shouldn't linger in today's "Completed" section forever.
                guard dose.scheduledAt >= startOfToday else { continue }
                buckets.completed.append(dose)
            case .upcoming, .snoozed:
                if dose.scheduledAt >= tonightStart {
                    buckets.tonight.append(dose)
                } else if dose.scheduledAt.timeIntervalSince(now) <= soonWindow {
                    buckets.comingUpSoon.append(dose)
                } else {
                    buckets.laterToday.append(dose)
                }
            }
        }

        buckets.overdue.sort { $0.scheduledAt < $1.scheduledAt }
        buckets.takeNow.sort { $0.scheduledAt < $1.scheduledAt }
        buckets.comingUpSoon.sort { $0.scheduledAt < $1.scheduledAt }
        buckets.laterToday.sort { $0.scheduledAt < $1.scheduledAt }
        buckets.tonight.sort { $0.scheduledAt < $1.scheduledAt }
        buckets.completed.sort { $0.scheduledAt < $1.scheduledAt }

        return buckets
    }

    struct ComingUpGroup: Identifiable {
        let date: Date
        var items: [DisplayDoseItem]
        var id: Date { date }
    }

    /// The next `.upcoming` occurrence of every medication beyond today, grouped by date.
    /// Prefers a persisted `ScheduledDose` when one exists within the materialization
    /// window; falls back to a live-computed forecast (`DoseForecastService`) for
    /// medications whose next dose falls beyond it — e.g. an infrequent `.cycle` or
    /// `.phased` regimen — so they don't silently vanish from this list.
    static func longRangeComingUp(
        medications: [Medication],
        statusFor: (ScheduledDose) -> DoseStatus,
        engine: DoseScheduleEngine,
        preferences: AppPreferences,
        forecastLimit: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [ComingUpGroup] {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now

        let items: [DisplayDoseItem] = medications.compactMap { medication in
            if let nextPersisted = medication.scheduledDoses
                .filter({ $0.scheduledAt >= startOfTomorrow && statusFor($0) == .upcoming })
                .min(by: { $0.scheduledAt < $1.scheduledAt })
            {
                return DisplayDoseItem(dose: nextPersisted, status: .upcoming)
            }
            return DoseForecastService.nextOccurrence(
                for: medication,
                engine: engine,
                after: startOfTomorrow,
                limit: forecastLimit,
                preferences: preferences
            )
        }

        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.dose.scheduledAt) }
        return grouped
            .map { day, items in ComingUpGroup(date: day, items: items.sorted { $0.dose.scheduledAt < $1.dose.scheduledAt }) }
            .sorted { $0.date < $1.date }
    }
}
