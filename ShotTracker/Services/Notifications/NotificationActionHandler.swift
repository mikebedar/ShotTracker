import Foundation
import SwiftData
import UserNotifications

/// Routes Take/Snooze/Skip taps on a dose reminder notification into the same
/// `AppDependencies.recordDoseAction` path the in-app buttons use, so a dose can be
/// resolved without ever opening the app. Registered as the notification-center delegate
/// at launch (`ShotTrackerApp`).
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    /// Category + action identifiers shared with `NotificationScheduler`.
    enum Identifier {
        static let doseCategory = "DOSE_REMINDER"
        /// Same, without Snooze — for medications whose reminder policy disallows it.
        static let doseCategoryNoSnooze = "DOSE_REMINDER_NO_SNOOZE"
        static let take = "DOSE_TAKE"
        static let snooze = "DOSE_SNOOZE"
        static let skip = "DOSE_SKIP"
    }

    /// Set once at launch; needed to resolve an occurrenceKey back to its dose.
    @MainActor var modelContainer: ModelContainer?

    static func categories() -> Set<UNNotificationCategory> {
        let withSnooze = doseCategory()
        let withoutSnooze = UNNotificationCategory(
            identifier: Identifier.doseCategoryNoSnooze,
            actions: withSnooze.actions.filter { $0.identifier != Identifier.snooze },
            intentIdentifiers: [],
            options: []
        )
        return [withSnooze, withoutSnooze]
    }

    static func doseCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: Identifier.doseCategory,
            actions: [
                UNNotificationAction(identifier: Identifier.take, title: "Take", options: []),
                UNNotificationAction(identifier: Identifier.snooze, title: "Snooze", options: []),
                UNNotificationAction(identifier: Identifier.skip, title: "Skip", options: [.destructive]),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionType: DoseActionType
        switch response.actionIdentifier {
        case Identifier.take: actionType = .taken
        case Identifier.snooze: actionType = .snoozed
        case Identifier.skip: actionType = .skipped
        default:
            // A plain tap on the banner just opens the app — nothing to record.
            return
        }

        guard let occurrenceKey = response.notification.request.content.userInfo["occurrenceKey"] as? String else {
            return
        }

        apply(actionType, occurrenceKey: occurrenceKey)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Keep reminders visible even while the app is open.
        [.banner, .list, .sound]
    }

    @MainActor
    private func apply(_ action: DoseActionType, occurrenceKey: String) {
        guard let container = modelContainer else { return }
        let context = container.mainContext

        var descriptor = FetchDescriptor<ScheduledDose>(
            predicate: #Predicate { $0.occurrenceKey == occurrenceKey }
        )
        descriptor.fetchLimit = 1
        guard let dose = (try? context.fetch(descriptor))?.first else { return }

        AppDependencies.shared.recordDoseAction(action, dose: dose, context: context)
    }
}
