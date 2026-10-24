import SwiftUI
import AtelierTheme

/// ShotTracker's Atelier theme, compiled into the app and the widget (an explicit build-file reference, like
/// `TodayWidgetSnapshot`), so both rebuild the same theme from the person's `ThemePreferences`.
///
/// It is `Theme.generated(from:)` over ShotTracker's purple (accent and the status tones are solved for contrast), with
/// ShotTracker's warm neutrals in place of the generator's brand-tinted greys, SF Rounded titles, the app's card and
/// button radii, and two app tones for the statuses Atelier has no tone for (`.late`, `.snoozed`). The accent is solved
/// again on those neutrals (`with(brand:)`). `ShotTrackerThemeTests` holds it to `ContrastRequirements.strict`.
///
/// Atelier's `Theme` is spelt `AtelierTheme.Theme` here: in the app, ShotTracker's own `Theme` token namespace shadows it.
nonisolated enum ShotTrackerTheme {
    static let id = "shottracker"

    /// ShotTracker's purple (`ColorAccent` light, before the asset catalog went).
    static let brand = ColorValue(hex: "#6D5398")

    static let theme: AtelierTheme.Theme = {
        let generated = AtelierTheme.Theme.generated(from: brand, name: "ShotTracker", id: id)
        let warm = generated.with {
            $0.summary = "ShotTracker's purple on warm neutrals, rounded titles."
            $0.typography.displayDesign = .rounded
            $0.radii.card = 20
            $0.radii.control = 13
            // The warm neutrals ShotTracker shipped with (its former colorsets), light and dark.
            $0.colors.surface.base = .hex(light: "#F9F6F1", dark: "#16130E")
            $0.colors.surface.raised = .hex(light: "#FFFDFA", dark: "#23201A")
            $0.colors.surface.subtle = .hex(light: "#F5F1E9", dark: "#2C2922")
            $0.colors.surface.sunken = .hex(light: "#EFEAE0", dark: "#110F0B")
            $0.colors.surface.overlay = .hex(light: "#FFFDFA", dark: "#2C2922")
            $0.colors.content.primary = .hex(light: "#2B261B", dark: "#F4F1EC")
            $0.colors.content.secondary = .hex(light: "#686358", dark: "#BBB7AF")
            $0.colors.content.tertiary = .hex(light: "#908C82", dark: "#838078")
            $0.colors.border.subtle = .hex(light: "#DDD9D0", dark: "#403D35")
            // Darker than the old #BBB7AE / #5C584E (1.9:1 and 2.6:1 on the ground): a strong border is a UI colour, 3:1.
            $0.colors.border.strong = .hex(light: "#8F8A80", dark: "#6E6A60")
            $0.colors.tones[.neutral] = ToneColors(base: .hex(light: "#6F6B63", dark: "#A9A49A"))
            $0.colors.tones[.late] = ToneColors(base: .hex(light: "#00717C", dark: "#57B5BF"))
            $0.colors.tones[.snoozed] = ToneColors(base: .hex(light: "#755D9D", dark: "#B49CE1"))
        }
        // Solve the accent (and its subtle and selected fills) again on the warm grounds.
        return warm.with(brand: brand)
    }()

    /// What the theme picker offers: ShotTracker's own first, then Atelier's.
    static let themes: [AtelierTheme.Theme] = [theme] + AtelierTheme.Theme.builtIn

    /// A fresh install: ShotTracker's theme, everything else following the system.
    static let defaults = ThemePreferences(themeID: id)

    /// The key under which the app hands the person's `ThemePreferences` (JSON) to the widget, in the App Group's defaults.
    static let widgetPreferencesKey = "atelier.themePreferences"

    /// The widget's theme: the app's last-written preferences, else ShotTracker's default.
    static func resolved(from data: Data?) -> AtelierTheme.Theme {
        let preferences = data.flatMap { try? JSONDecoder().decode(ThemePreferences.self, from: $0) } ?? defaults
        return preferences.resolvedTheme(in: themes)
    }
}

extension Tone {
    /// Taken after its window closed (`DoseStatus.takenLate`): ShotTracker's teal.
    nonisolated static let late = Tone("late")
    /// Snoozed (`DoseStatus.snoozed`): ShotTracker's lavender.
    nonisolated static let snoozed = Tone("snoozed")
}

extension WidgetDoseStatus {
    /// The status's tone: the same mapping as the app's `DoseStatus.tone` (`WidgetToneParityTests` holds them equal).
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
}
