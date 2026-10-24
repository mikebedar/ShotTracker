//
//  ShotTrackerApp.swift
//  ShotTracker
//
//  Created by Michael Bedar on 4/11/26.
//

import Atelier
import SwiftUI
import SwiftData
import UserNotifications

@main
struct ShotTrackerApp: App {
    @State private var dependencies = AppDependencies.shared
    /// Theme, accent, light/dark, text size, motion and haptics (Settings → Appearance).
    @State private var appearance = AppAppearance.makePreferences()

    /// Kept alive for the app's lifetime — the notification center holds its delegate weakly.
    private let notificationActionHandler = NotificationActionHandler()

    var sharedModelContainer: ModelContainer = {
        do {
            return try MedicationModelContainer.makeSharedContainer()
        } catch {
            fatalError("Could not create medication model container: \(error)")
        }
    }()

    init() {
        // `-deviceTimeZone <id>` (Debug): pretend the device is in another zone, before
        // anything reads the clock.
        LaunchOptions.applyDeviceTimeZoneOverride()
        // Wire Take/Snooze/Skip notification actions before any notification can arrive.
        notificationActionHandler.modelContainer = sharedModelContainer
        UNUserNotificationCenter.current().delegate = notificationActionHandler
    }

    var body: some Scene {
        let container = sharedModelContainer
        WindowGroup {
            ContentView()
                .environment(\.appDependencies, dependencies)
                // Outside the TabView: toasts (with Undo), confirmations and errors for every tab.
                .atelierPresenter(toastPlacement: AppAppearance.toastPlacement)
                // Outermost: the theme every view and component reads.
                .atelierPreferences(appearance)
                .task { AppAppearance.publishToWidget(appearance.values) }
                .onChange(of: appearance.values) { _, values in AppAppearance.publishToWidget(values) }
                // UI tests get a throwaway suite for @AppStorage too (Today's list/calendar mode).
                .defaultAppStorage(LaunchOptions.defaults)
        }
        .modelContainer(container)
        // The daily re-plan (`BackgroundRefresh`); SwiftUI registers the identifier.
        .backgroundTask(.appRefresh(BackgroundRefresh.taskIdentifier)) {
            await BackgroundRefresh.run(container: container)
        }
    }
}
