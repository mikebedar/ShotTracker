import BackgroundTasks
import Foundation
import OSLog
import SwiftData

/// The daily `BGAppRefreshTask` that keeps reminders flowing when the app isn't opened.
///
/// iOS keeps only 64 pending notifications, so with several medications the plan covers a
/// few days; without a refresh the reminders simply stopped once the user didn't open the
/// app for that long. Each run does what a foreground does — regenerate the materialized
/// window (`DoseRepository.refreshSchedules`), re-plan the budgeted notifications (refill
/// reminders first), republish the widget — and asks for the next run early tomorrow
/// morning, before the day's first windows open.
///
/// Safe to run any number of times: generation is keyed by `occurrenceKey` and reconciled
/// (no duplicate doses), the plan replaces everything pending, and the work is a few
/// fetches plus at most 64 `add` calls.
///
/// Trying it in the simulator (Debug build, app running, then pause it in the debugger):
///
///     e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"bedar.net.ShotTracker.refresh"]
///
/// and continue; the `background` log category reports the run. The iOS 27 simulator
/// refuses `submitTaskRequest` ("not available on this platform"), so there the call
/// finds no scheduled request; on a simulator, launch with `-runBackgroundRefresh`
/// (Debug) to run the same handler once after launch instead.
enum BackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in `ShotTracker/Info.plist`.
    nonisolated static let taskIdentifier = "bedar.net.ShotTracker.refresh"

    /// The local hour the next run may start from (iOS picks the actual moment).
    nonisolated static let earliestBeginHour = 4

    nonisolated static let log = Logger(subsystem: "bedar.net.ShotTracker", category: "background")

    /// The next `earliestBeginHour`:00 on the local clock strictly after `now` — today's
    /// if it's still ahead, else tomorrow's. Matching by hour keeps it right across DST.
    nonisolated static func nextEarliestBegin(after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: now,
            matching: DateComponents(hour: earliestBeginHour, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(24 * 60 * 60)
    }

    /// Asks for the next run. A newer request replaces an older one with the same
    /// identifier, so calling this on every launch and background is fine.
    nonisolated static func scheduleNext(now: Date = .now) {
        let earliest = nextEarliestBegin(after: now)
        Task {
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = earliest
            do {
                try await BGTaskScheduler.shared.submitTaskRequest(request)
                log.info("Next background refresh from \(earliest.description, privacy: .public)")
            } catch {
                // A device with Background App Refresh off refuses; the app still re-plans
                // on every launch, foreground and time change.
                log.error("Couldn't schedule background refresh: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The planning step of a run, without the notification center: regenerate the
    /// window at `now`, then compute the budgeted notification plan. Unit-tested.
    @MainActor
    static func plan(
        context: ModelContext,
        engine: DoseScheduleEngine,
        evaluator: DoseStatusEvaluator,
        preferences: AppPreferences,
        now: Date,
        calendar: Calendar = .current
    ) throws -> NotificationScheduler.Plan? {
        try DoseRepository.refreshSchedules(in: context, engine: engine, preferences: preferences, referenceDate: now)
        return NotificationScheduler.plan(
            in: context, preferences: preferences, evaluator: evaluator, engine: engine, now: now, calendar: calendar
        )
    }

    /// The task handler (`ShotTrackerApp`'s `.backgroundTask(.appRefresh(…))`).
    @MainActor
    static func run(container: ModelContainer) async {
        await run(context: container.mainContext)
    }

    @MainActor
    static func run(context: ModelContext) async {
        log.info("Background refresh started")
        scheduleNext()
        await AppDependencies.shared.performBackgroundRefresh(context: context)
        log.info("Background refresh finished: \(AppDependencies.shared.notificationScheduler.lastPlannedCount) reminders handed to the system")
    }
}
