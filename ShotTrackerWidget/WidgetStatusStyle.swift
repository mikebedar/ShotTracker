import AtelierTheme
import SwiftUI

/// Status → colour/symbol for the widget. The colour is the status's Atelier tone (`WidgetDoseStatus.tone`, the
/// app's `DoseStatus.tone` mapping) in the person's theme, which the app hands over through the App Group; the widget
/// links only the `AtelierTheme` product (never `Atelier`). Symbols mirror `DoseStatus.symbolName`.
enum WidgetStatusStyle {
    static func color(_ status: WidgetDoseStatus) -> ThemeColor {
        .tone(status.tone)
    }

    static func symbol(_ status: WidgetDoseStatus) -> String {
        switch status {
        case .overdue: "exclamationmark.triangle.fill"
        case .due: "bell.fill"
        case .upcoming: "clock"
        case .snoozed: "moon.fill"
        case .takenOnTime, .takenLate: "checkmark.circle.fill"
        case .skipped: "xmark.circle"
        }
    }

    static func title(_ status: WidgetDoseStatus) -> String {
        switch status {
        case .upcoming: "Upcoming"
        case .due: "Due"
        case .overdue: "Overdue"
        case .takenOnTime: "Taken"
        case .takenLate: "Taken late"
        case .skipped: "Skipped"
        case .snoozed: "Snoozed"
        }
    }

    /// Display priority — mirrors the Today screen's ordering (overdue first).
    static func priority(_ status: WidgetDoseStatus) -> Int {
        switch status {
        case .overdue: 0
        case .due: 1
        case .snoozed: 2
        case .upcoming: 3
        case .takenLate, .takenOnTime, .skipped: 4
        }
    }
}

/// A single item resolved to its live status at the entry's date.
struct ResolvedWidgetItem: Identifiable {
    let item: WidgetDoseItem
    let status: WidgetDoseStatus
    var id: String { item.occurrenceKey }
}

extension TodayWidgetSnapshot {
    /// Items resolved at `date` and re-sorted overdue-first (the writer's order can drift as
    /// time advances and an upcoming dose becomes due/overdue).
    func resolvedItems(at date: Date) -> [ResolvedWidgetItem] {
        items(relevantAt: date)
            .map { ResolvedWidgetItem(item: $0, status: $0.resolvedStatus(now: date)) }
            .sorted { a, b in
                let pa = WidgetStatusStyle.priority(a.status)
                let pb = WidgetStatusStyle.priority(b.status)
                return pa != pb ? pa < pb : a.item.scheduledAt < b.item.scheduledAt
            }
    }
}
