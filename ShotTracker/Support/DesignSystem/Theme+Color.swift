import SwiftUI
import Atelier

/// Color tokens: a typed facade over the Atelier theme's semantic roles (`ShotTrackerTheme`, or whatever theme the
/// person picked in Settings → Appearance). Each is a `ThemeColor`, a `ShapeStyle` that resolves against the
/// environment's theme, colour scheme and contrast at draw time, so these follow the theme, dark mode and Increase
/// Contrast without an asset catalog. (Until 2026-10-23 they were 25 hand-converted colorsets.)
///
/// Prefer Atelier's own spelling in new code (`.foregroundStyle(.contentSecondary)`, `.surface(.raised)`); these names
/// stay so existing call sites keep their meaning.
extension Theme {
    nonisolated enum Color {
        static var background: ThemeColor { .surfaceBase }
        static var surface: ThemeColor { .surfaceRaised }
        static var surfaceSecondary: ThemeColor { .surfaceSubtle }
        static var border: ThemeColor { .borderSubtle }
        static var borderStrong: ThemeColor { .borderStrong }
        static var textPrimary: ThemeColor { .contentPrimary }
        static var textSecondary: ThemeColor { .contentSecondary }
        static var textTertiary: ThemeColor { .contentTertiary }

        static var accent: ThemeColor { .accent }
        /// Accent-coloured text and small marks (links, the emphasised adherence figure).
        static var accentStrong: ThemeColor { .contentLink }
        static var accentSoft: ThemeColor { .tone(.accent, .subtleFill) }
        static var accentOn: ThemeColor { .contentOnAccent }

        /// Status colours by status (`DoseStatus.tone`): content and subtle fill.
        static var statusUpcoming: ThemeColor { DoseStatus.upcoming.themeColor }
        static var statusUpcomingSoft: ThemeColor { DoseStatus.upcoming.themeSoftColor }
        static var statusDue: ThemeColor { DoseStatus.due.themeColor }
        static var statusDueSoft: ThemeColor { DoseStatus.due.themeSoftColor }
        static var statusOverdue: ThemeColor { DoseStatus.overdue.themeColor }
        static var statusOverdueSoft: ThemeColor { DoseStatus.overdue.themeSoftColor }
        static var statusTaken: ThemeColor { DoseStatus.takenOnTime.themeColor }
        static var statusTakenSoft: ThemeColor { DoseStatus.takenOnTime.themeSoftColor }
        static var statusLate: ThemeColor { DoseStatus.takenLate.themeColor }
        static var statusLateSoft: ThemeColor { DoseStatus.takenLate.themeSoftColor }
        static var statusSkipped: ThemeColor { DoseStatus.skipped.themeColor }
        static var statusSkippedSoft: ThemeColor { DoseStatus.skipped.themeSoftColor }
        static var statusSnoozed: ThemeColor { DoseStatus.snoozed.themeColor }
        static var statusSnoozedSoft: ThemeColor { DoseStatus.snoozed.themeSoftColor }

        /// Per-medication avatar tint, parameterized by a hue angle (0..<360) derived from
        /// the medication's identity (see `Medication.avatarHue`) — mirrors the source
        /// design's `Avatar` component, which computes `background/color/border` from a
        /// single `hue` value per medication rather than a fixed palette. Computed at
        /// runtime since hue is continuous, not a fixed set; Atelier has no hue avatar.
        static func avatarTint(hueDegrees: Double, dark: Bool) -> AvatarTint {
            AvatarTint(
                background: oklch(lightness: dark ? 0.32 : 0.9, chroma: dark ? 0.05 : 0.045, hueDegrees: hueDegrees),
                foreground: oklch(lightness: dark ? 0.86 : 0.36, chroma: dark ? 0.06 : 0.09, hueDegrees: hueDegrees),
                border: oklch(lightness: dark ? 0.46 : 0.8, chroma: dark ? 0.07 : 0.06, hueDegrees: hueDegrees)
            )
        }
    }
}

struct AvatarTint {
    let background: SwiftUI.Color
    let foreground: SwiftUI.Color
    let border: SwiftUI.Color
}

/// An avatar colour at OKLCH lightness/chroma/hue, through Atelier's OKLab conversion (gamut-mapped into sRGB).
private nonisolated func oklch(lightness: Double, chroma: Double, hueDegrees: Double) -> SwiftUI.Color {
    SwiftUI.Color(OKLCH(l: lightness, c: chroma, h: hueDegrees).colorValue(in: .sRGB))
}
