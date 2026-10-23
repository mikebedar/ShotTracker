import SwiftUI
import SwiftData

struct AppRootView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext

    private enum Tab: Hashable { case today, medications, history, settings }
    @State private var selectedTab: Tab = .today

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem {
                    Label("Today", systemImage: "calendar")
                }
                .accessibilityIdentifier(AccessibilityID.todayTab)
                .tag(Tab.today)

            MedicationListView()
                .tabItem {
                    Label("Medications", systemImage: "pills")
                }
                .accessibilityIdentifier(AccessibilityID.medicationsTab)
                .tag(Tab.medications)

            MedicationHistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                .accessibilityIdentifier(AccessibilityID.historyTab)
                .tag(Tab.history)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier(AccessibilityID.settingsTab)
                .tag(Tab.settings)
        }
        .task {
            await dependencies.bootstrapIfNeeded(context: modelContext)
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
        .modelContainer(try! MedicationModelContainer.makeSharedContainer())
        .environment(\.appDependencies, .shared)
}
