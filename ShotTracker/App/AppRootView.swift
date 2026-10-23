import SwiftUI
import SwiftData

struct AppRootView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    private enum AppTab: Hashable { case today, medications, history, settings }
    @State private var selectedTab: AppTab = .today

    var body: some View {
        // `Tab` (not `.tabItem`) so each identifier lands on the tab bar button itself;
        // `.accessibilityIdentifier` on a `.tabItem` view tagged the tab's *content*.
        TabView(selection: $selectedTab) {
            Tab("Today", systemImage: "calendar", value: AppTab.today) {
                TodayView()
            }
            .accessibilityIdentifier(AccessibilityID.todayTab)

            Tab("Medications", systemImage: "pills", value: AppTab.medications) {
                MedicationListView()
            }
            .accessibilityIdentifier(AccessibilityID.medicationsTab)

            Tab("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90", value: AppTab.history) {
                MedicationHistoryView()
            }
            .accessibilityIdentifier(AccessibilityID.historyTab)

            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
            .accessibilityIdentifier(AccessibilityID.settingsTab)
        }
        .task {
            await dependencies.bootstrapIfNeeded(context: modelContext)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                dependencies.sceneBecameActive(context: modelContext)
            }
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
