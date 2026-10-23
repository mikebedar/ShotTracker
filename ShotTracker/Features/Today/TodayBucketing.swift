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

        let superseded = DoseSupersession.supersededIDs(in: doses, now: now, calendar: calendar)

        for dose in doses {
            guard dose.scheduledAt < startOfTomorrow else { continue }
            // An archived medication's leftover rows never belong on Today.
            if dose.medication?.isActive == false { continue }

            switch statusFor(dose) {
            case .overdue:
                // A dose missed on an earlier day stays overdue until a later dose of the
                // same medication comes due — then it's history (a miss), not a to-do.
                // Showing every missed daily pill from the past week helps no one.
                if superseded.contains(dose.id) { continue }
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

/// Which unresolved doses a later dose of the same medication has replaced. A dose from
/// an earlier day is superseded once that medication has another dose scheduled today
/// (a new day's dose replaces yesterday's miss — taking both a few hours apart is the
/// double dose a "keep to schedule" med warns against). A weekly med missed yesterday,
/// whose next dose is days away, stays overdue. Today's doses are never superseded — a
/// missed morning dose can still be taken late in the afternoon.
enum DoseSupersession {
    static func supersededIDs(in doses: [ScheduledDose], now: Date, calendar: Calendar = .current) -> Set<UUID> {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        var latestStartedByMedication: [UUID: Date] = [:]
        for dose in doses where dose.scheduledAt < endOfToday {
            guard let medicationID = dose.medication?.id else { continue }
            latestStartedByMedication[medicationID] = max(latestStartedByMedication[medicationID] ?? .distantPast, dose.scheduledAt)
        }

        var result = Set<UUID>()
        for dose in doses where dose.scheduledAt < startOfToday && dose.completedAt == nil && dose.lastAction != .skipped {
            guard let medicationID = dose.medication?.id,
                  let latest = latestStartedByMedication[medicationID],
                  latest > dose.scheduledAt
            else { continue }
            result.insert(dose.id)
        }
        return result
    }

    /// Convenience for one medication's own rows.
    static func supersededIDs(for medication: Medication, now: Date, calendar: Calendar = .current) -> Set<UUID> {
        supersededIDs(in: medication.scheduledDoses, now: now, calendar: calendar)
    }
}
