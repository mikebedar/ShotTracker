import Foundation
import Observation
import OSLog
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

    private(set) var hasBootstrapped = false
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var preferencesRefreshTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "bedar.net.ShotTracker", category: "dependencies")

    func bootstrapIfNeeded(context: ModelContext) async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        #if DEBUG
        if LaunchOptions.seedsDemoData {
            DemoData.seedIfEmpty(in: context)
        }
        #endif

        regenerate(context: context)
        await notificationScheduler.refreshAuthorizationStatus()
        await rescheduleNotifications(context: context)
        refreshWidgetSnapshot(context: context)
        // Keep re-planning daily while the app isn't opened (see `BackgroundRefresh`).
        if !LaunchOptions.isUITesting {
            BackgroundRefresh.scheduleNext()
        }
    }

    /// Regenerates the materialized window, then (coalesced) reschedules notifications
    /// and republishes the widget. Every schedule-affecting change goes through here.
    func refreshSchedules(context: ModelContext) {
        regenerate(context: context)
        scheduleNotificationRefresh(context: context)
        refreshWidgetSnapshot(context: context)
    }

    /// The app came to the foreground: the day may have changed (the 7…90-day window
    /// moves, yesterday's widget snapshot is stale, the pending-notification budget needs
    /// topping up) and notification permission may have changed in Settings.
    func sceneBecameActive(context: ModelContext) {
        guard hasBootstrapped else { return }
        refreshSchedules(context: context)
    }

    /// Settings that change generation (routine windows, reminder lead) or reminders
    /// (the global toggles) used to apply only at the next dose action. Coalesced so
    /// dragging a time picker doesn't regenerate on every tick.
    func preferencesChanged(context: ModelContext) {
        preferencesRefreshTask?.cancel()
        preferencesRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.refreshSchedules(context: context)
        }
    }

    /// The clock or the time zone changed (`significantTimeChangeNotification`: midnight,
    /// DST, a manual change; `NSSystemTimeZoneDidChange`: travel). Doses keep their home
    /// zone's instants, but "today", the widget's day and the notification text (which
    /// names the local time) all depend on the device clock.
    func timeChanged(context: ModelContext) {
        guard hasBootstrapped else { return }
        refreshSchedules(context: context)
    }

    /// One `BGAppRefreshTask` run (`BackgroundRefresh`): regenerate, re-plan the
    /// notifications through `BackgroundRefresh.plan` (queued behind any reschedule in
    /// flight), republish the widget. Doesn't need `bootstrapIfNeeded` — a background
    /// launch never shows a scene — and is idempotent.
    func performBackgroundRefresh(context: ModelContext) async {
        let previous = notificationTask
        let preferences = preferencesStore.preferences
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                if let plan = try BackgroundRefresh.plan(
                    context: context,
                    engine: self.scheduleEngine,
                    evaluator: self.statusEvaluator,
                    preferences: preferences,
                    now: .now
                ) {
                    BackgroundRefresh.log.info("Planned \(plan.requests.count) reminders of \(plan.candidateCount) candidates (\(plan.requests.filter { $0.identifier.hasPrefix("refill-") }.count) refill)")
                    await self.notificationScheduler.applyIfAuthorized(plan)
                }
            } catch {
                Self.log.error("Background refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        notificationTask = task
        // The system ends a background task that runs too long; pass that on.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        refreshWidgetSnapshot(context: context)
    }

    func recordDoseAction(_ action: DoseActionType, dose: ScheduledDose, context: ModelContext) {
        do {
            try DoseRepository.applyAction(action, to: dose, context: context)
        } catch {
            Self.log.error("Dose action \(action.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // A taken dose can re-anchor a rolling schedule; regenerate before rescheduling.
        refreshSchedules(context: context)
    }

    /// Logs a refill and refreshes what depends on supply (the refill reminder and the
    /// widget) — `MedicationDetailView` used to call the repository directly, so the
    /// run-out reminder kept pointing at the old date.
    func logRefill(_ quantity: Int, for medication: Medication, context: ModelContext) {
        do {
            try MedicationRepository.logRefill(quantity, for: medication, in: context)
        } catch {
            Self.log.error("Refill failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        scheduleNotificationRefresh(context: context)
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

    private func regenerate(context: ModelContext) {
        do {
            try DoseRepository.refreshSchedules(
                in: context,
                engine: scheduleEngine,
                preferences: preferencesStore.preferences
            )
        } catch {
            // The UI keeps showing existing data if a refresh fails.
            Self.log.error("Schedule refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One reschedule at a time: `rescheduleAll` clears every pending request and adds
    /// the new plan, so two overlapping runs could interleave and lose reminders.
    private func scheduleNotificationRefresh(context: ModelContext) {
        let previous = notificationTask
        notificationTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.rescheduleNotifications(context: context)
        }
    }

    private func rescheduleNotifications(context: ModelContext) async {
        await notificationScheduler.rescheduleAll(
            in: context,
            preferences: preferencesStore.preferences,
            evaluator: statusEvaluator,
            engine: scheduleEngine
        )
    }
}

extension EnvironmentValues {
    @Entry var appDependencies: AppDependencies = .shared
}
