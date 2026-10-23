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

    func rescheduleAll(
        in context: ModelContext,
        preferences: AppPreferences,
        evaluator: DoseStatusEvaluator,
        engine: DoseScheduleEngine? = nil
    ) async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        var descriptor = FetchDescriptor<ScheduledDose>(sortBy: [SortDescriptor(\.scheduledAt)])
        descriptor.includePendingChanges = true
        guard let doses = try? context.fetch(descriptor) else { return }

        let now = Date.now
        let doseReminders = NotificationPlanner.doseReminders(
            for: doses, preferences: preferences, evaluator: evaluator, now: now
        )
        var refillReminders: [NotificationPlanner.Planned] = []
        if let engine {
            var medicationDescriptor = FetchDescriptor<Medication>(predicate: #Predicate { $0.isActive })
            medicationDescriptor.includePendingChanges = true
            let medications = (try? context.fetch(medicationDescriptor)) ?? []
            refillReminders = Self.refillReminders(for: medications, engine: engine, preferences: preferences, now: now)
        }
        let plan = NotificationPlanner.budgeted(doseReminders: doseReminders, refillReminders: refillReminders)

        center.removeAllPendingNotificationRequests()
        for planned in plan {
            try? await center.add(request(for: planned))
        }
        lastPlannedCount = plan.count
        lastCandidateCount = doseReminders.count + refillReminders.count
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

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: planned.fireDate)
        return UNNotificationRequest(
            identifier: planned.identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
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
