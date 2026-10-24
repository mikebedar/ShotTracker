import SwiftUI
import Atelier

/// Single source of truth for DoseStatus -> tone/colour/icon. A status *is* an Atelier tone
/// (`Badge(…, tone: status.tone)`, `.foregroundStyle(.tone(status.tone))`); `themeColor` and
/// `themeSoftColor` are that tone's content and subtle fill, so the theme's contrast solving and
/// Increase Contrast apply. The widget mirrors this mapping in `WidgetStatusStyle`.
extension DoseStatus {
    /// upcoming → info, due → warning, overdue → danger, taken → success, taken late → `.late`
    /// (teal), skipped → neutral, snoozed → `.snoozed` (lavender).
    nonisolated var tone: Tone {
        switch self {
        case .upcoming: .info
        case .due: .warning
        case .overdue: .danger
        case .takenOnTime: .success
        case .takenLate: .late
        case .skipped: .neutral
        case .snoozed: .snoozed
        }
    }

    nonisolated var themeColor: ThemeColor { .tone(tone) }

    nonisolated var themeSoftColor: ThemeColor { .tone(tone, .subtleFill) }

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
