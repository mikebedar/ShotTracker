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
        // Wire Take/Snooze/Skip notification actions before any notification can arrive.
        notificationActionHandler.modelContainer = sharedModelContainer
        UNUserNotificationCenter.current().delegate = notificationActionHandler
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appDependencies, dependencies)
        }
        .modelContainer(sharedModelContainer)
    }
}
