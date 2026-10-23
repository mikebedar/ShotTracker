import Foundation
import SwiftData
import WidgetKit

/// Writes the App Group snapshot the home-screen widget renders from. The widget runs in a
/// separate process and can't read the SwiftData store, so the app publishes a small
/// Codable projection of today's doses (overdue first, then upcoming-today) whenever
/// schedules or dose state change, then asks WidgetKit to reload.
@MainActor
enum WidgetSnapshotWriter {
    /// Cap on how many doses ride in the snapshot — the largest widget shows far fewer,
    /// and it bounds the payload size.
    static let itemLimit = 10

    static func write(context: ModelContext, evaluator: DoseStatusEvaluator, preferences: AppPreferences) {
        guard let url = WidgetShared.snapshotURL() else { return }

        let snapshot = buildSnapshot(context: context, evaluator: evaluator, preferences: preferences)
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // A failed snapshot write must never affect the app; the widget just shows
            // its last good state (or an empty state) until the next successful write.
            return
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Pure(ish) projection: fetch → bucket (reusing `TodayBucketing`) → order → map.
    /// Split out so it can be exercised by tests without touching the file system.
    static func buildSnapshot(
        context: ModelContext,
        evaluator: DoseStatusEvaluator,
        preferences: AppPreferences,
        now: Date = .now
    ) -> TodayWidgetSnapshot {
        let doses = fetchDoses(context: context)
        let buckets = TodayBucketing.bucket(
            doses: doses,
            statusFor: { evaluator.effectiveStatus(for: $0, now: now) },
            now: now
        )

        // Overdue first, then the actionable/upcoming buckets in urgency order. Completed
        // doses and the long-range list are intentionally excluded from the widget.
        let ordered = buckets.overdue
            + buckets.takeNow
            + buckets.comingUpSoon
            + buckets.laterToday
            + buckets.tonight

        // Tomorrow's doses ride along so the widget is right after midnight even if the
        // app isn't opened (it used to show yesterday's leftovers, then nothing, until
        // the next launch). The widget only shows an item once its day has come.
        let calendar = Calendar.current
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let endOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow) ?? startOfTomorrow
        let tomorrow = doses.filter {
            $0.scheduledAt >= startOfTomorrow && $0.scheduledAt < endOfTomorrow
                && $0.medication?.isActive != false
                && $0.completedAt == nil && $0.lastAction != .skipped
        }

        let items = ordered.prefix(itemLimit).map(makeItem) + tomorrow.prefix(itemLimit).map(makeItem)

        return TodayWidgetSnapshot(
            generatedAt: now,
            showMedicationNames: preferences.showMedicationNamesInWidget,
            items: Array(items)
        )
    }

    private static func fetchDoses(context: ModelContext) -> [ScheduledDose] {
        var descriptor = FetchDescriptor<ScheduledDose>(sortBy: [SortDescriptor(\ScheduledDose.scheduledAt)])
        descriptor.includePendingChanges = true
        return (try? context.fetch(descriptor)) ?? []
    }

    static func makeItem(_ dose: ScheduledDose) -> WidgetDoseItem {
        let medication = dose.medication
        return WidgetDoseItem(
            occurrenceKey: dose.occurrenceKey,
            medicationID: medication?.id.uuidString,
            displayName: medication?.displayName ?? "Medication",
            kindSymbol: (medication?.kind ?? .oral).symbolName,
            avatarHue: medication?.avatarHue ?? 0,
            takeWithFood: medication?.takeWithFood ?? false,
            timingLabel: dose.timingLabel,
            scheduledAt: dose.scheduledAt,
            windowEnd: dose.windowEnd,
            isFlexibleWindow: dose.isFlexibleWindow,
            snoozedUntil: dose.snoozedUntil,
            isTaken: dose.lastAction == .taken,
            isSkipped: dose.lastAction == .skipped,
            storedStatus: dose.status.rawValue
        )
    }
}
