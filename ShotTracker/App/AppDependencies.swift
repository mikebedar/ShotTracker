import Foundation
import Observation
import SwiftData
import SwiftUI
import WidgetKit

@MainActor
@Observable
final class AppDependencies {
    static let shared = AppDependencies()

    let scheduleEngine = DoseScheduleEngine()
    let statusEvaluator = DoseStatusEvaluator()
    let lookupService = MedicationLookupService()
    let notificationScheduler = NotificationScheduler()
    let preferencesStore = AppPreferencesStore.shared
    let syncSettingsStore = SyncSettingsStore.shared

    private(set) var hasBootstrapped = false

    func bootstrapIfNeeded(context: ModelContext) async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        do {
            try DoseRepository.refreshSchedules(
                in: context,
                engine: scheduleEngine,
                preferences: preferencesStore.preferences
            )
        } catch {
            // Keep the app running even if sample data or refresh work fails.
        }

        await notificationScheduler.refreshAuthorizationStatus()
        await notificationScheduler.rescheduleAll(
            in: context,
            preferences: preferencesStore.preferences,
            evaluator: statusEvaluator,
            engine: scheduleEngine
        )

        refreshWidgetSnapshot(context: context)
    }

    func refreshSchedules(context: ModelContext) {
        do {
            try DoseRepository.refreshSchedules(
                in: context,
                engine: scheduleEngine,
                preferences: preferencesStore.preferences
            )
        } catch {
            // The UI will continue to show existing data if refresh fails.
        }

        Task {
            await notificationScheduler.rescheduleAll(
                in: context,
                preferences: preferencesStore.preferences,
                evaluator: statusEvaluator,
                engine: scheduleEngine
            )
        }

        refreshWidgetSnapshot(context: context)
    }

    func recordDoseAction(_ action: DoseActionType, dose: ScheduledDose, context: ModelContext) {
        do {
            try DoseRepository.applyAction(action, to: dose, context: context)
        } catch {
            return
        }

        notificationScheduler.cancelNotifications(for: dose.occurrenceKey)
        Task {
            await notificationScheduler.rescheduleAll(
                in: context,
                preferences: preferencesStore.preferences,
                evaluator: statusEvaluator,
                engine: scheduleEngine
            )
        }

        refreshWidgetSnapshot(context: context)
    }

    /// Republishes the home-screen widget's App Group snapshot. Called wherever schedules
    /// or dose state change, and directly when a widget-affecting setting is toggled.
    func refreshWidgetSnapshot(context: ModelContext) {
        WidgetSnapshotWriter.write(
            context: context,
            evaluator: statusEvaluator,
            preferences: preferencesStore.preferences
        )
    }
}

extension EnvironmentValues {
    @Entry var appDependencies: AppDependencies = .shared
}
