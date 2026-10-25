import Atelier
import Foundation
import WidgetKit

/// The person's appearance (Atelier's `AtelierPreferences`: theme, accent, light/dark, text size, motion, haptics),
/// installed at the window root, plus the hand-off to the widget.
///
/// Values live in `LaunchOptions.defaults` (UI tests get the throwaway suite) under `atelier.`; a fresh install shows
/// `ShotTrackerTheme`. The widget can't read them, so every change is also written to the App Group as one
/// `ThemePreferences` JSON (`ShotTrackerTheme.widgetPreferencesKey`) and the widget rebuilds the same theme from it.
@MainActor
enum AppAppearance {
    static func makePreferences() -> AtelierPreferences {
        #if DEBUG
        // `-atelierTheme <id>` (Debug): start on another theme for screenshots, e.g. `canary` to find what ignores the
        // theme, or `system` to check that native chrome is untouched.
        if LaunchOptions.atelierThemeID != nil || LaunchOptions.atelierMotion != nil || LaunchOptions.atelierAppearance != nil {
            var values = ShotTrackerTheme.defaults
            if let id = LaunchOptions.atelierThemeID { values.themeID = id }
            if let motion = LaunchOptions.atelierMotion.flatMap(MotionPreference.init(rawValue:)) { values.motion = motion }
            if let appearance = LaunchOptions.atelierAppearance.flatMap(AppearanceMode.init(rawValue:)) { values.appearance = appearance }
            return AtelierPreferences(transient: values, themes: ShotTrackerTheme.themes + [.canary],
                                      defaults: ShotTrackerTheme.defaults)
        }
        #endif
        return AtelierPreferences(store: LaunchOptions.defaults, themes: ShotTrackerTheme.themes,
                                  defaults: ShotTrackerTheme.defaults)
    }

    /// Where toasts float: above the tab bar, where ShotTracker's own toast always sat (see CLAUDE.md, UI: Atelier).
    /// `-toastPlacement top` (Debug) shows Atelier's iPhone default instead.
    static var toastPlacement: ToastPlacement {
        #if DEBUG
        if LaunchOptions.toastPlacementTop { return .top }
        #endif
        return .bottom
    }

    /// Writes the preferences for the widget and asks it to redraw. Called at launch and on every change.
    static func publishToWidget(_ values: ThemePreferences) {
        // Fixture appearance must not leak into the shared widget preferences.
        guard !LaunchOptions.isUITesting else { return }
        guard let defaults = UserDefaults(suiteName: WidgetShared.appGroupID),
              let data = try? JSONEncoder().encode(values) else { return }
        guard defaults.data(forKey: ShotTrackerTheme.widgetPreferencesKey) != data else { return }
        defaults.set(data, forKey: ShotTrackerTheme.widgetPreferencesKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
