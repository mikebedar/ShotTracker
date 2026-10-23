import Foundation
import SwiftData
import UserNotifications

@MainActor
final class NotificationScheduler {
    private let center: UNUserNotificationCenter

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        center.setNotificationCategories([NotificationActionHandler.doseCategory()])
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

        center.removeAllPendingNotificationRequests()

        var descriptor = FetchDescriptor<ScheduledDose>(sortBy: [SortDescriptor(\.scheduledAt)])
        descriptor.includePendingChanges = true

        guard let doses = try? context.fetch(descriptor) else { return }

        for dose in doses {
            let status = evaluator.effectiveStatus(for: dose)
            guard status == .upcoming || status == .due || status == .snoozed else { continue }

            let policy = dose.medication?.regimens.active?.activeReminderPolicy ?? ReminderPolicy()
            let requestDates = notificationDates(for: dose, policy: policy, preferences: preferences)
            let timeSensitive = dose.medication?.timeSensitiveNotifications ?? preferences.timeSensitiveByDefault

            for (index, fireDate) in requestDates.enumerated() where fireDate > .now {
                let content = UNMutableNotificationContent()
                let name = dose.medication?.displayName ?? "Medication"
                content.title = "Medication reminder"
                var body = "\(name) is due \(dose.timingLabel.replacingOccurrences(of: "-", with: " "))."
                if dose.medication?.takeWithFood == true {
                    body += " Take with food."
                }
                content.body = body
                content.sound = policy.playSound ? .default : nil
                content.interruptionLevel = timeSensitive ? .timeSensitive : .active
                content.categoryIdentifier = NotificationActionHandler.Identifier.doseCategory
                content.userInfo = [
                    "occurrenceKey": dose.occurrenceKey,
                    "medicationID": dose.medication?.id.uuidString ?? "",
                ]

                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: fireDate
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(
                    identifier: notificationIdentifier(for: dose.occurrenceKey, index: index),
                    content: content,
                    trigger: trigger
                )

                try? await center.add(request)
            }
        }

        if let engine {
            await scheduleRefillReminders(in: context, engine: engine, preferences: preferences)
        }
    }

    /// One reminder per supply-tracked medication, a few days ahead of its projected
    /// run-out date, so a refill can happen before doses are missed.
    private func scheduleRefillReminders(
        in context: ModelContext,
        engine: DoseScheduleEngine,
        preferences: AppPreferences
    ) async {
        guard preferences.globalNotificationsEnabled else { return }

        var descriptor = FetchDescriptor<Medication>(predicate: #Predicate { $0.isActive })
        descriptor.includePendingChanges = true
        guard let medications = try? context.fetch(descriptor) else { return }

        let calendar = Calendar.current
        for medication in medications where medication.isTrackingSupply {
            guard let projection = SupplyForecastService.projection(
                for: medication,
                engine: engine,
                preferences: preferences
            ) else { continue }

            guard
                let leadDay = calendar.date(
                    byAdding: .day,
                    value: -SupplyForecastService.refillReminderLeadDays,
                    to: projection.runOutDate
                ),
                let fireDate = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: leadDay),
                fireDate > .now
            else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Refill reminder"
            let unitLabel = medication.supplyUnitLabel ?? "doses"
            content.body = "\(medication.displayName) runs out around \(projection.runOutDate.formatted(date: .abbreviated, time: .omitted)) — \(medication.totalRemaining) \(unitLabel) left. Time to refill."
            content.sound = .default

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
            let request = UNNotificationRequest(
                identifier: "refill-\(medication.id.uuidString)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
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

    private func notificationDates(
        for dose: ScheduledDose,
        policy: ReminderPolicy,
        preferences: AppPreferences
    ) -> [Date] {
        guard policy.isEnabled, preferences.globalNotificationsEnabled else { return [] }

        var intervals = policy.escalationIntervalsMinutes
        if !preferences.globalDueRemindersEnabled || !policy.dueRemindersEnabled {
            intervals.removeAll(where: { $0 == 0 })
        }
        if !preferences.globalOverdueRemindersEnabled || !policy.overdueRemindersEnabled {
            intervals = intervals.filter { $0 == 0 }
        }

        // Base the nudge on the reminder instant (near a window's close) rather than the
        // window start, so a flexible dose doesn't ping the moment its window opens.
        let baseDate = dose.snoozedUntil ?? dose.reminderAt ?? dose.scheduledAt
        let limitedIntervals = Array(intervals.prefix(policy.maxReminderCount))
        return limitedIntervals.map { minutes in
            baseDate.addingTimeInterval(TimeInterval(minutes * 60))
        }
    }

    private func notificationIdentifier(for occurrenceKey: String, index: Int) -> String {
        "\(occurrenceKey)-\(index)"
    }
}
