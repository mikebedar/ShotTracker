import Foundation

/// Projects when a supply-tracked medication will run out, by walking the same forecast
/// occurrences the calendar uses and counting doses against the on-hand total. Stateless,
/// same shape as `DoseForecastService`.
enum SupplyForecastService {
    /// How far ahead to search for the run-out dose. Beyond this, supply is effectively
    /// "not a concern" and no projection is shown.
    static let horizonDays = 365

    /// Days before the projected run-out to fire the refill reminder.
    static let refillReminderLeadDays = 3

    struct Projection {
        /// The day the last on-hand unit gets consumed.
        let runOutDate: Date
        /// Whole days from now until `runOutDate` (0 = runs out today).
        let daysRemaining: Int
    }

    static func projection(
        for medication: Medication,
        engine: DoseScheduleEngine,
        preferences: AppPreferences,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Projection? {
        guard medication.isActive, medication.isTrackingSupply else { return nil }
        let remaining = medication.totalRemaining
        guard remaining > 0 else { return nil }
        guard let horizon = calendar.date(byAdding: .day, value: horizonDays, to: now) else { return nil }

        // Forecast occurrences from now forward; a dose whose window is still open counts
        // as future consumption, one that already closed does not.
        let upcoming = DoseForecastService
            .occurrences(for: [medication], engine: engine, in: now...horizon, preferences: preferences)
            .map(\.dose)
            .filter { $0.windowEnd > now }
            .sorted { $0.scheduledAt < $1.scheduledAt }

        guard upcoming.count >= remaining else { return nil }  // outlasts the horizon

        let runOutDose = upcoming[remaining - 1]
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: runOutDose.scheduledAt)
        ).day ?? 0
        return Projection(runOutDate: runOutDose.scheduledAt, daysRemaining: max(0, days))
    }

    /// Short display string, e.g. "Runs out Jul 28 (~12 days)" — nil when no projection.
    static func summaryText(for projection: Projection) -> String {
        let date = projection.runOutDate.formatted(date: .abbreviated, time: .omitted)
        switch projection.daysRemaining {
        case 0: return "Runs out today"
        case 1: return "Runs out tomorrow (\(date))"
        default: return "Runs out \(date) (~\(projection.daysRemaining) days)"
        }
    }
}
