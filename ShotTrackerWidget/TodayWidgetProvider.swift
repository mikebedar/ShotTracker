import WidgetKit
import Foundation

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: TodayWidgetSnapshot
}

struct TodayWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        let snapshot = context.isPreview ? .placeholder : Self.loadSnapshot()
        completion(TodayEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snapshot = Self.loadSnapshot()
        let now = Date()
        let calendar = Calendar.current
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(3600)
        let endOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfTomorrow) ?? startOfTomorrow

        // Refresh at each future window boundary today and tomorrow (the snapshot carries
        // tomorrow's doses), plus midnight, so a dose flips upcoming → due → overdue and
        // the day turns over without waiting for the app to write.
        var dates: Set<Date> = [now, startOfTomorrow]
        for item in snapshot.items {
            for boundary in [item.scheduledAt, item.deadline, item.snoozedUntil].compactMap({ $0 }) {
                if boundary > now && boundary < endOfTomorrow { dates.insert(boundary) }
            }
        }

        let entries = dates.sorted().map { TodayEntry(date: $0, snapshot: snapshot) }
        // Past tomorrow the snapshot has nothing more to say; the app rewrites it whenever
        // it's foregrounded or a dose changes.
        completion(Timeline(entries: entries, policy: .after(endOfTomorrow)))
    }

    static func loadSnapshot() -> TodayWidgetSnapshot {
        guard
            let url = WidgetShared.snapshotURL(),
            let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(TodayWidgetSnapshot.self, from: data)
        else {
            return .empty
        }
        return snapshot
    }
}

extension TodayWidgetSnapshot {
    /// A representative sample for the widget gallery / placeholder.
    static var placeholder: TodayWidgetSnapshot {
        let now = Date()
        func item(_ key: String, _ name: String, _ hue: Double, start: TimeInterval, end: TimeInterval, flexible: Bool) -> WidgetDoseItem {
            WidgetDoseItem(
                occurrenceKey: key, displayName: name, kindSymbol: "pills.fill",
                avatarHue: hue, takeWithFood: false, timingLabel: "Morning",
                scheduledAt: now.addingTimeInterval(start), windowEnd: now.addingTimeInterval(end),
                isFlexibleWindow: flexible, snoozedUntil: nil, isTaken: false, isSkipped: false,
                storedStatus: WidgetDoseStatus.upcoming.rawValue
            )
        }
        return TodayWidgetSnapshot(
            generatedAt: now,
            showMedicationNames: true,
            items: [
                item("a", "Metformin", 210, start: -7200, end: -3600, flexible: true),
                item("b", "Lisinopril", 20, start: 3600, end: 10800, flexible: true),
                item("c", "Vitamin D", 90, start: 21600, end: 25200, flexible: false),
            ]
        )
    }
}
