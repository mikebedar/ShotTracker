import SwiftUI
import SwiftData
import UIKit

struct AppRootView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    private enum AppTab: Hashable { case today, medications, history, settings }
    @State private var selectedTab: AppTab = .today

    var body: some View {
        // Tab bar buttons can't carry our identifiers: on iOS 27 the floating tab bar's
        // buttons report their SF Symbol name as the identifier, and neither
        // `.accessibilityIdentifier` on a `Tab` nor on the `UITabBarItem` changes that
        // (tried both, 2026-10-23). The identifiers below tag each tab's content; UI tests
        // find tab buttons by title (`XCUIApplication.tab(_:)`).
        TabView(selection: $selectedTab) {
            Tab("Today", systemImage: "calendar", value: AppTab.today) {
                TodayView()
                    .accessibilityIdentifier(AccessibilityID.todayTab)
            }

            Tab("Medications", systemImage: "pills", value: AppTab.medications) {
                MedicationListView()
                    .accessibilityIdentifier(AccessibilityID.medicationsTab)
            }

            Tab("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90", value: AppTab.history) {
                MedicationHistoryView()
                    .accessibilityIdentifier(AccessibilityID.historyTab)
            }

            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
                    .accessibilityIdentifier(AccessibilityID.settingsTab)
            }
        }
        // Parts of the day for "Home: Night" away from home, from the routine windows.
        .environment(\.dayParts, dependencies.preferencesStore.preferences.dayParts)
        .task {
            await dependencies.bootstrapIfNeeded(context: modelContext)
            if LaunchOptions.runsBackgroundRefresh {
                await BackgroundRefresh.run(context: modelContext)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dependencies.sceneBecameActive(context: modelContext)
            } else if phase == .background, !LaunchOptions.isUITesting {
                BackgroundRefresh.scheduleNext()
            }
        }
        // Midnight, DST, a manual clock change, or landing in another time zone: re-plan
        // (the local times in notification text and "today" itself depend on the clock).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            dependencies.timeChanged(context: modelContext)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            LaunchOptions.resetSystemTimeZoneUnlessOverridden()
            dependencies.timeChanged(context: modelContext)
        }
        .onOpenURL { url in
            // The home-screen widget opens `shottracker://today` — land on the Today tab.
            if url.scheme == WidgetShared.deepLinkScheme {
                selectedTab = .today
            }
        }
    }
}

#Preview {
    AppRootView()
        .modelContainer(try! MedicationModelContainer.makeSharedContainer(inMemory: true))
        .environment(\.appDependencies, .shared)
}
