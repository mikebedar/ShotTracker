//
//  ShotTrackerApp.swift
//  ShotTracker
//
//  Created by Michael Bedar on 4/11/26.
//

import SwiftUI
import SwiftData
import UserNotifications

@main
struct ShotTrackerApp: App {
    @State private var dependencies = AppDependencies.shared

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
