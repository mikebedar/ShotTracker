import Foundation
import Observation
import SwiftData
import UserNotifications

@MainActor
@Observable
final class NotificationScheduler {
    @ObservationIgnored private let center: UNUserNotificationCenter

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        center.setNotificationCategories(NotificationActionHandler.categories())
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorization() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            // Leave status refresh to the next read.
        }

        await refreshAuthorizationStatus()
    }

    /// What should be pending, and how many reminders it had to choose from.
    struct Plan: Equatable {
        var requests: [NotificationPlanner.Planned]
        var candidateCount: Int
    }

    func rescheduleAll(
        in context: ModelContext,
        preferences: AppPreferences,
        evaluator: DoseStatusEvaluator,
        engine: DoseScheduleEngine? = nil
    ) async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        guard let plan = Self.plan(in: context, preferences: preferences, evaluator: evaluator, engine: engine, now: .now) else { return }
        await apply(plan)
    }

    /// The budgeted plan for the store as it is: refill reminders first, then the
    /// soonest dose reminders, at most 64. Pure apart from the fetch, so the background
    /// refresh and tests can compute it without the notification center.
    static func plan(
        in context: ModelContext,
        preferences: AppPreferences,
        evaluator: DoseStatusEvaluator,
        engine: DoseScheduleEngine?,
        now: Date,
        calendar: Calendar = .current
    ) -> Plan? {
        var descriptor = FetchDescriptor<ScheduledDose>(sortBy: [SortDescriptor(\.scheduledAt)])
        descriptor.includePendingChanges = true
        guard let doses = try? context.fetch(descriptor) else { return nil }

        let doseReminders = NotificationPlanner.doseReminders(
            for: doses, preferences: preferences, evaluator: evaluator, now: now, calendar: calendar
        )
        var refillReminders: [NotificationPlanner.Planned] = []
        if let engine {
            var medicationDescriptor = FetchDescriptor<Medication>(predicate: #Predicate { $0.isActive })
            medicationDescriptor.includePendingChanges = true
            let medications = (try? context.fetch(medicationDescriptor)) ?? []
            refillReminders = Self.refillReminders(for: medications, engine: engine, preferences: preferences, now: now, calendar: calendar)
        }
        return Plan(
            requests: NotificationPlanner.budgeted(doseReminders: doseReminders, refillReminders: refillReminders),
            candidateCount: doseReminders.count + refillReminders.count
        )
    }

    /// Applies a plan computed elsewhere (the background refresh), if reminders can arrive.
    func applyIfAuthorized(_ plan: Plan) async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }
        await apply(plan)
    }

    /// Replaces everything pending with `plan`.
    private func apply(_ plan: Plan) async {
        center.removeAllPendingNotificationRequests()
        for planned in plan.requests {
            try? await center.add(request(for: planned))
        }
        lastPlannedCount = plan.requests.count
        lastCandidateCount = plan.candidateCount
    }

    /// How many requests the last reschedule handed to the system, and how many it had
    /// to choose from (the difference is what the 64-request budget deferred).
    private(set) var lastPlannedCount = 0
    private(set) var lastCandidateCount = 0

    private func request(for planned: NotificationPlanner.Planned) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = planned.title
        content.body = planned.body
        content.sound = planned.playSound ? .default : nil
        content.interruptionLevel = planned.timeSensitive ? .timeSensitive : .active
        if let category = planned.categoryIdentifier {
            content.categoryIdentifier = category
        }
        var userInfo: [String: String] = [:]
        if let key = planned.occurrenceKey { userInfo["occurrenceKey"] = key }
        if let medicationID = planned.medicationID { userInfo["medicationID"] = medicationID }
        content.userInfo = userInfo

        return UNNotificationRequest(
            identifier: planned.identifier,
            content: content,
            trigger: Self.trigger(for: planned.fireDate)
        )
    }

    /// A calendar trigger pinned to the fire date's instant: the components carry their
    /// time zone, so a reminder planned in New York still fires at the same moment after
    /// the phone lands in Paris (floating components would fire at the same *wall-clock*
    /// time in the new zone until the next re-plan).
    static func trigger(for fireDate: Date, timeZone: TimeZone = .current) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        components.calendar = calendar
        components.timeZone = timeZone
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    /// One reminder per supply-tracked medication, a few days ahead of its projected
    /// run-out date, so a refill can happen before doses are missed.
    static func refillReminders(
        for medications: [Medication],
        engine: DoseScheduleEngine,
        preferences: AppPreferences,
        now: Date,
        calendar: Calendar = .current
    ) -> [NotificationPlanner.Planned] {
        guard preferences.globalNotificationsEnabled else { return [] }

        return medications.compactMap { medication in
            guard
                medication.isActive, medication.isTrackingSupply,
                let projection = SupplyForecastService.projection(
                    for: medication, engine: engine, preferences: preferences, now: now, calendar: calendar
                ),
                let leadDay = calendar.date(
                    byAdding: .day,
                    value: -SupplyForecastService.refillReminderLeadDays,
                    to: projection.runOutDate
                ),
                let fireDate = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: leadDay),
                fireDate > now
            else { return nil }

            let unitLabel = medication.supplyUnitLabel ?? "doses"
            return NotificationPlanner.Planned(
                identifier: "refill-\(medication.id.uuidString)",
                fireDate: fireDate,
                title: "Refill \(medication.displayName)",
                body: "Runs out around \(projection.runOutDate.formatted(date: .abbreviated, time: .omitted)) — \(medication.totalRemaining) \(unitLabel) left.",
                timeSensitive: false,
                playSound: true,
                categoryIdentifier: nil,
                occurrenceKey: nil,
                medicationID: medication.id.uuidString
            )
        }
    }

    func cancelNotifications(for occurrenceKey: String) {
        Task {
            let pending = await center.pendingNotificationRequests()
            let identifiers = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(occurrenceKey) }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
        }
    }
}
