import Foundation
import SwiftUI
import Testing
import Atelier
@testable import ShotTracker

/// ShotTracker's Atelier theme (`ShotTrackerTheme`): contrast, the status → tone mapping, and the hand-off to the
/// widget.
@MainActor
struct ShotTrackerThemeTests {
    private var theme: AtelierTheme.Theme { ShotTrackerTheme.theme }

    /// Generated themes pass `.strict` by construction; ShotTracker swaps in its own warm neutrals, so check the result.
    @Test(arguments: [ColorSchemeContrast.standard, .increased])
    func passesStrictContrast(contrast: ColorSchemeContrast) {
        let report = theme.contrastReport(.strict, contrast: contrast)
        let failures = report.failures.map { "\($0.id): \(String(format: "%.2f", $0.ratio)) < \($0.minimum)" }
        #expect(report.passes, "\(failures.joined(separator: "\n"))")
    }

    /// Every status has its own tone, and the app tones exist in the theme (an unknown tone falls back to neutral).
    @Test func everyStatusHasATone() {
        for status in DoseStatus.allCases {
            #expect(theme.colors.tones[status.tone] != nil, "\(status) → \(status.tone)")
        }
        let tones = Set(DoseStatus.allCases.map(\.tone))
        #expect(tones.count == DoseStatus.allCases.count, "two statuses share a tone")
    }

    @Test func statusesKeepTheirMeaning() {
        #expect(DoseStatus.overdue.tone == .danger)
        #expect(DoseStatus.due.tone == .warning)
        #expect(DoseStatus.upcoming.tone == .info)
        #expect(DoseStatus.takenOnTime.tone == .success)
        #expect(DoseStatus.skipped.tone == .neutral)
        #expect(DoseStatus.takenLate.tone == .late)
        #expect(DoseStatus.snoozed.tone == .snoozed)
    }

    /// A fresh install shows ShotTracker's theme; the widget rebuilds whatever the app wrote, and ShotTracker's
    /// theme when nothing was written (or the JSON is unreadable).
    @Test func widgetRebuildsTheAppsTheme() throws {
        #expect(ShotTrackerTheme.defaults.resolvedTheme(in: ShotTrackerTheme.themes).id == ShotTrackerTheme.id)
        #expect(ShotTrackerTheme.resolved(from: nil).id == ShotTrackerTheme.id)
        #expect(ShotTrackerTheme.resolved(from: Data("not json".utf8)).id == ShotTrackerTheme.id)

        let warm = ThemePreferences(themeID: "warm", accent: .preset(.green))
        let data = try JSONEncoder().encode(warm)
        let rebuilt = ShotTrackerTheme.resolved(from: data)
        #expect(rebuilt == warm.resolvedTheme(in: ShotTrackerTheme.themes))
        #expect(rebuilt.id == "warm")
    }

    /// The widget colours a status with the same tone as the app (`WidgetDoseStatus.tone` mirrors `DoseStatus.tone`).
    @Test func widgetTonesMatchTheApp() throws {
        for status in DoseStatus.allCases {
            let widget = try #require(WidgetDoseStatus(rawValue: status.rawValue))
            #expect(widget.tone == status.tone, "\(status)")
        }
    }

    /// Titles keep SF Rounded, as `Theme.Font.display` did.
    @Test func titlesAreRounded() {
        #expect(theme.typography.displayDesign == .rounded)
    }
}
