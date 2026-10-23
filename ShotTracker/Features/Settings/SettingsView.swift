import SwiftUI

struct SettingsView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @State private var preferencesStore = AppPreferencesStore.shared
    @State private var syncSettingsStore = SyncSettingsStore.shared

    private let editableSlots: [TimingAnchorKind] = [
        .morning,
        .noon,
        .evening,
        .night,
        .bedtime,
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Toggle("Enable notifications", isOn: Binding(
                        get: { preferencesStore.preferences.globalNotificationsEnabled },
                        set: { preferencesStore.preferences.globalNotificationsEnabled = $0 }
                    ))
                    .accessibilityIdentifier(AccessibilityID.notificationToggle)

                    Toggle("Due reminders", isOn: Binding(
                        get: { preferencesStore.preferences.globalDueRemindersEnabled },
                        set: { preferencesStore.preferences.globalDueRemindersEnabled = $0 }
                    ))

                    Toggle("Overdue reminders", isOn: Binding(
                        get: { preferencesStore.preferences.globalOverdueRemindersEnabled },
                        set: { preferencesStore.preferences.globalOverdueRemindersEnabled = $0 }
                    ))

                    Toggle("Time-sensitive by default", isOn: Binding(
                        get: { preferencesStore.preferences.timeSensitiveByDefault },
                        set: { preferencesStore.preferences.timeSensitiveByDefault = $0 }
                    ))
                    Text("Time-sensitive reminders can break through Focus and Do Not Disturb. Individual medications can override this in their settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("Request Notification Permission") {
                        Task {
                            await dependencies.notificationScheduler.requestAuthorization()
                        }
                    }

                    Stepper(
                        "Remind \(preferencesStore.preferences.windowReminderLeadMinutes) min before a window closes",
                        value: Binding(
                            get: { preferencesStore.preferences.windowReminderLeadMinutes },
                            set: { preferencesStore.preferences.windowReminderLeadMinutes = $0 }
                        ),
                        in: 0...240,
                        step: 15
                    )
                }

                Section {
                    ForEach(editableSlots) { slot in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(slot.title)
                                .font(.subheadline.weight(.medium))
                            DatePicker(
                                "From",
                                selection: slotWindowBinding(for: slot, edge: \.start),
                                displayedComponents: .hourAndMinute
                            )
                            DatePicker(
                                "To",
                                selection: slotWindowBinding(for: slot, edge: \.end),
                                displayedComponents: .hourAndMinute
                            )
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Routine Windows")
                } footer: {
                    Text("Time ranges for flexible slots. A dose is on time anywhere in its window; medications set to a specific time ignore these.")
                }

                Section {
                    Toggle("Show medication names in widget", isOn: Binding(
                        get: { preferencesStore.preferences.showMedicationNamesInWidget },
                        set: { newValue in
                            preferencesStore.preferences.showMedicationNamesInWidget = newValue
                            dependencies.refreshWidgetSnapshot(context: modelContext)
                        }
                    ))
                } header: {
                    Text("Home Screen Widget")
                } footer: {
                    Text("When off, the widget hides medication names — it shows only times, counts, and status, so nothing sensitive appears on your home screen.")
                }

                Section("Sync") {
                    Toggle("Enable iCloud Sync", isOn: $syncSettingsStore.isICloudSyncEnabled)
                        .accessibilityIdentifier(AccessibilityID.syncToggle)
                    Text("Sync remains local-first for now. Turning this on stores your preference so CloudKit-backed migration can be added later without changing the rest of the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func slotWindowBinding(for slot: TimingAnchorKind, edge: WritableKeyPath<DoseWindow, ClockTime>) -> Binding<Date> {
        Binding<Date>(
            get: {
                preferencesStore.defaultWindow(for: slot)[keyPath: edge].applying(to: .now, calendar: .current)
            },
            set: { newValue in
                var window = preferencesStore.defaultWindow(for: slot)
                window[keyPath: edge] = ClockTime(date: newValue)
                // Keep end ≥ start so the window never inverts.
                if window.end.hour * 60 + window.end.minute < window.start.hour * 60 + window.start.minute {
                    if edge == \DoseWindow.start { window.end = window.start } else { window.start = window.end }
                }
                preferencesStore.setDefaultWindow(window, for: slot)
            }
        )
    }
}
