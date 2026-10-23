import SwiftUI

/// Single source of truth for DoseStatus -> color/icon, built on the Theme token layer.
/// Replaces the previously-divergent copies in `AppFormatting.tint(for:)` and
/// `DoseCalendarView.Coordinator.color(for:)`.
extension DoseStatus {
    nonisolated var themeColor: Color {
        switch self {
        case .upcoming: Theme.Color.statusUpcoming
        case .due: Theme.Color.statusDue
        case .overdue: Theme.Color.statusOverdue
        case .takenOnTime: Theme.Color.statusTaken
        case .takenLate: Theme.Color.statusLate
        case .skipped: Theme.Color.statusSkipped
        case .snoozed: Theme.Color.statusSnoozed
        }
    }

    nonisolated var themeSoftColor: Color {
        switch self {
        case .upcoming: Theme.Color.statusUpcomingSoft
        case .due: Theme.Color.statusDueSoft
        case .overdue: Theme.Color.statusOverdueSoft
        case .takenOnTime: Theme.Color.statusTakenSoft
        case .takenLate: Theme.Color.statusLateSoft
        case .skipped: Theme.Color.statusSkippedSoft
        case .snoozed: Theme.Color.statusSnoozedSoft
        }
    }

    nonisolated var symbolName: String {
        switch self {
        case .upcoming: "clock"
        case .due: "bell.fill"
        case .overdue: "exclamationmark.triangle.fill"
        case .takenOnTime: "checkmark.circle.fill"
        case .takenLate: "checkmark.circle.trianglebadge.exclamationmark"
        case .skipped: "minus.circle"
        case .snoozed: "moon.fill"
        }
    }
}
