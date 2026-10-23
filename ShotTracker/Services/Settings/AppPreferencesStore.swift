import Foundation
import Observation

struct AppPreferences: Codable, Equatable {
    var defaultSlotWindows: [String: DoseWindow]
    var windowReminderLeadMinutes: Int
    var globalNotificationsEnabled: Bool
    var globalDueRemindersEnabled: Bool
    var globalOverdueRemindersEnabled: Bool
    var timeSensitiveByDefault: Bool
    var showMedicationNamesInWidget: Bool

    // Decoding older stored preferences (which lacked these keys, or carried the old
    // `defaultSlotTimes`/quiet-hours keys) still succeeds: missing keys default below,
    // extra keys are ignored.
    private enum CodingKeys: String, CodingKey {
        case defaultSlotWindows, windowReminderLeadMinutes, globalNotificationsEnabled
        case globalDueRemindersEnabled, globalOverdueRemindersEnabled, timeSensitiveByDefault
        case showMedicationNamesInWidget
    }

    init(
        defaultSlotWindows: [String: DoseWindow],
        windowReminderLeadMinutes: Int,
        globalNotificationsEnabled: Bool,
        globalDueRemindersEnabled: Bool,
        globalOverdueRemindersEnabled: Bool,
        timeSensitiveByDefault: Bool,
        showMedicationNamesInWidget: Bool
    ) {
        self.defaultSlotWindows = defaultSlotWindows
        self.windowReminderLeadMinutes = windowReminderLeadMinutes
        self.globalNotificationsEnabled = globalNotificationsEnabled
        self.globalDueRemindersEnabled = globalDueRemindersEnabled
        self.globalOverdueRemindersEnabled = globalOverdueRemindersEnabled
        self.timeSensitiveByDefault = timeSensitiveByDefault
        self.showMedicationNamesInWidget = showMedicationNamesInWidget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultSlotWindows = try container.decodeIfPresent([String: DoseWindow].self, forKey: .defaultSlotWindows)
            ?? AppPreferences.defaultWindows
        windowReminderLeadMinutes = try container.decodeIfPresent(Int.self, forKey: .windowReminderLeadMinutes) ?? 60
        globalNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalNotificationsEnabled) ?? true
        globalDueRemindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalDueRemindersEnabled) ?? true
        globalOverdueRemindersEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalOverdueRemindersEnabled) ?? true
        timeSensitiveByDefault = try container.decodeIfPresent(Bool.self, forKey: .timeSensitiveByDefault) ?? true
        showMedicationNamesInWidget = try container.decodeIfPresent(Bool.self, forKey: .showMedicationNamesInWidget) ?? true
    }

    static let defaultWindows: [String: DoseWindow] = [
        TimingAnchorKind.morning.rawValue: TimingAnchorKind.morning.defaultWindow!,
        TimingAnchorKind.noon.rawValue: TimingAnchorKind.noon.defaultWindow!,
        TimingAnchorKind.evening.rawValue: TimingAnchorKind.evening.defaultWindow!,
        TimingAnchorKind.night.rawValue: TimingAnchorKind.night.defaultWindow!,
        TimingAnchorKind.bedtime.rawValue: TimingAnchorKind.bedtime.defaultWindow!,
    ]

    static let `default` = AppPreferences(
        defaultSlotWindows: defaultWindows,
        windowReminderLeadMinutes: 60,
        globalNotificationsEnabled: true,
        globalDueRemindersEnabled: true,
        globalOverdueRemindersEnabled: true,
        timeSensitiveByDefault: true,
        showMedicationNamesInWidget: true
    )
}

@MainActor
@Observable
final class AppPreferencesStore {
    static let shared = AppPreferencesStore()

    private let defaults = LaunchOptions.defaults
    private let storageKey = "medicationTracker.appPreferences"

    var preferences: AppPreferences {
        didSet { persist() }
    }

    init() {
        if
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(AppPreferences.self, from: data)
        {
            preferences = decoded
        } else {
            preferences = .default
        }
    }

    func defaultWindow(for kind: TimingAnchorKind) -> DoseWindow {
        preferences.defaultSlotWindows[kind.rawValue]
            ?? kind.defaultWindow
            ?? DoseWindow(start: ClockTime(hour: 8, minute: 0), end: ClockTime(hour: 10, minute: 0))
    }

    func setDefaultWindow(_ window: DoseWindow, for kind: TimingAnchorKind) {
        preferences.defaultSlotWindows[kind.rawValue] = window
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
