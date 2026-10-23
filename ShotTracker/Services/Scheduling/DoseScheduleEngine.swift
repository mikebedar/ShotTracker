import Foundation

struct GeneratedDoseOccurrence: Identifiable, Hashable {
    var id: String { occurrenceKey }
    let occurrenceKey: String
    /// The window start (for a flexible slot) or the exact time (for a point).
    let scheduledAt: Date
    /// The window end; nil for a precise (exact-time) occurrence.
    let windowEndAt: Date?
    /// When the reminder should fire — near the window's close, or the exact time.
    let reminderAt: Date
    let timingLabel: String
    let reminderWindowMinutes: Int
    let graceWindowMinutes: Int
}

/// A timing resolved to concrete clock times for a day: a window (`start`==`end` for a
/// precise point) plus when to remind.
struct ResolvedTiming: Hashable {
    let label: String
    let start: ClockTime
    let end: ClockTime
    let reminder: ClockTime
    let isWindow: Bool
    let reminderWindowMinutes: Int
}

final class DoseScheduleEngine {
    /// Generate the dose occurrences for a regimen within a date range.
    ///
    /// - `anchorOverride`: use this date instead of `regimen.anchorDate` as day-0 of the
    ///   recurrence (for `.rescheduleFromLastDose`, this is the last actual dose's day).
    /// - `rollingInterval`: when set, occurrences are generated purely by adding this
    ///   interval from the anchor (`anchor + n × interval`), ignoring the calendar matcher
    ///   — this is what makes a weekday-locked weekly regimen actually roll to follow the
    ///   last dose. When nil, the normal recurrence matcher is used.
    /// - `notBefore`: occurrences at or before this instant are excluded (skips the
    ///   just-taken slot so re-anchoring never fabricates a duplicate same-day dose).
    func generateOccurrences(
        for regimen: MedicationRegimen,
        medicationID: UUID,
        from startDate: Date,
        through endDate: Date,
        preferences: AppPreferences,
        anchorOverride: Date? = nil,
        rollingInterval: DateComponents? = nil,
        notBefore: Date? = nil
    ) -> [GeneratedDoseOccurrence] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: regimen.timeZoneIdentifier) ?? .current

        let startDay = calendar.startOfDay(for: min(startDate, endDate))
        let endDay = calendar.startOfDay(for: max(startDate, endDate))
        let anchorDay = calendar.startOfDay(for: anchorOverride ?? regimen.anchorDate)

        let occurrences: [GeneratedDoseOccurrence]
        if let rollingInterval {
            occurrences = rollingOccurrences(
                for: regimen, medicationID: medicationID, interval: rollingInterval,
                anchorDay: anchorDay, startDay: startDay, endDay: endDay,
                calendar: calendar, preferences: preferences
            )
        } else {
            occurrences = matchedOccurrences(
                for: regimen, medicationID: medicationID,
                anchorDay: anchorDay, startDay: startDay, endDay: endDay,
                calendar: calendar, preferences: preferences
            )
        }

        return occurrences
            .filter { occurrence in
                guard let notBefore else { return true }
                return occurrence.scheduledAt > notBefore
            }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    private func matchedOccurrences(
        for regimen: MedicationRegimen,
        medicationID: UUID,
        anchorDay: Date,
        startDay: Date,
        endDay: Date,
        calendar: Calendar,
        preferences: AppPreferences
    ) -> [GeneratedDoseOccurrence] {
        var occurrences: [GeneratedDoseOccurrence] = []
        var cursor = max(startDay, anchorDay)

        while cursor <= endDay {
            let daysFromAnchor = calendar.dateComponents([.day], from: anchorDay, to: cursor).day ?? 0

            guard daysFromAnchor >= 0 else {
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
                continue
            }

            let phase = activePhase(for: daysFromAnchor, regimen: regimen)
            let rule = phase?.recurrenceRule ?? regimen.recurrenceRule
            let timings = phase?.timings.isEmpty == false ? phase?.timings ?? [] : regimen.timings

            if matches(rule: rule, on: cursor, anchorDay: anchorDay, dayOffset: daysFromAnchor, calendar: calendar) {
                occurrences.append(contentsOf: makeOccurrences(on: cursor, timings: timings, regimen: regimen, medicationID: medicationID, calendar: calendar, preferences: preferences))
            }

            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }

        return occurrences
    }

    /// Rolling generation: step forward from the anchor by `interval`, emitting a dose
    /// at each step, ignoring the recurrence matcher (the anchor itself is the last real
    /// dose, so the first emitted occurrence is one interval later).
    private func rollingOccurrences(
        for regimen: MedicationRegimen,
        medicationID: UUID,
        interval: DateComponents,
        anchorDay: Date,
        startDay: Date,
        endDay: Date,
        calendar: Calendar,
        preferences: AppPreferences
    ) -> [GeneratedDoseOccurrence] {
        var occurrences: [GeneratedDoseOccurrence] = []
        var cursor = anchorDay
        var guardCounter = 0

        while cursor <= endDay {
            guardCounter += 1
            if guardCounter > 10_000 { break }  // safety against a zero/negative interval

            guard let next = calendar.date(byAdding: interval, to: cursor), next > cursor else { break }
            cursor = next

            guard cursor >= startDay else { continue }
            occurrences.append(contentsOf: makeOccurrences(on: cursor, timings: regimen.timings, regimen: regimen, medicationID: medicationID, calendar: calendar, preferences: preferences))
        }

        return occurrences
    }

    private func makeOccurrences(
        on day: Date,
        timings: [DailyTiming],
        regimen: MedicationRegimen,
        medicationID: UUID,
        calendar: Calendar,
        preferences: AppPreferences
    ) -> [GeneratedDoseOccurrence] {
        resolveTimings(timings, preferences: preferences).map { timing in
            let scheduledAt = timing.start.applying(to: day, calendar: calendar)
            let dayKey = Self.occurrenceDateFormatter.string(from: scheduledAt)
            let occurrenceKey = "\(medicationID.uuidString)-v\(regimen.version)-\(dayKey)-\(timing.label)"

            return GeneratedDoseOccurrence(
                occurrenceKey: occurrenceKey,
                scheduledAt: scheduledAt,
                windowEndAt: timing.isWindow ? timing.end.applying(to: day, calendar: calendar) : nil,
                reminderAt: timing.reminder.applying(to: day, calendar: calendar),
                timingLabel: timing.label,
                reminderWindowMinutes: timing.reminderWindowMinutes,
                graceWindowMinutes: regimen.graceWindowMinutes
            )
        }
    }

    private func activePhase(for dayOffset: Int, regimen: MedicationRegimen) -> RegimenPhase? {
        regimen.phases
            .sorted(by: { $0.startDayOffset < $1.startDayOffset })
            .first { phase in
                let phaseStart = phase.startDayOffset
                let phaseEnd = phase.durationDays.map { phaseStart + $0 - 1 } ?? Int.max
                return dayOffset >= phaseStart && dayOffset <= phaseEnd
            }
    }

    private func matches(
        rule: RecurrenceRule,
        on day: Date,
        anchorDay: Date,
        dayOffset: Int,
        calendar: Calendar
    ) -> Bool {
        switch rule.frequency {
        case .daily:
            return true
        case .intervalDays:
            return dayOffset % max(1, rule.intervalDays) == 0
        case .weekly:
            let weekday = calendar.component(.weekday, from: day)
            return rule.weekdays.isEmpty ? weekday == calendar.component(.weekday, from: anchorDay) : rule.weekdays.contains(weekday)
        case .monthly:
            let targetDay = min(max(1, rule.dayOfMonth), lastDayOfMonth(for: day, calendar: calendar))
            return calendar.component(.day, from: day) == targetDay
        case .cycle:
            let cycleLength = max(1, rule.cycleOnDays + rule.cycleOffDays)
            return dayOffset % cycleLength < max(1, rule.cycleOnDays)
        case .phased:
            return true
        }
    }

    private func resolveTimings(_ timings: [DailyTiming], preferences: AppPreferences) -> [ResolvedTiming] {
        let source = timings.isEmpty ? [DailyTiming(kind: .morning)] : timings

        return source.map { timing in
            let label = timing.title.replacingOccurrences(of: " ", with: "-").lowercased()

            if timing.kind == .exactTime {
                // A precise point: window collapses to the single time, remind at it.
                let time = timing.exactTime ?? timing.overrideTime ?? ClockTime(hour: 8, minute: 0)
                return ResolvedTiming(
                    label: label, start: time, end: time, reminder: time,
                    isWindow: false, reminderWindowMinutes: max(15, timing.reminderWindowMinutes)
                )
            }

            // A flexible slot: per-med custom window, else the global slot window.
            let window = timing.customWindow
                ?? preferences.defaultSlotWindows[timing.kind.rawValue]
                ?? timing.kind.defaultWindow
                ?? DoseWindow(start: ClockTime(hour: 8, minute: 0), end: ClockTime(hour: 10, minute: 0))
            let reminder = reminderTime(for: window, leadMinutes: preferences.windowReminderLeadMinutes)

            return ResolvedTiming(
                label: label, start: window.start, end: window.end, reminder: reminder,
                isWindow: true, reminderWindowMinutes: max(15, timing.reminderWindowMinutes)
            )
        }
    }

    /// Remind near a window's close: `end − lead`, never before the window opens.
    private func reminderTime(for window: DoseWindow, leadMinutes: Int) -> ClockTime {
        let startMinutes = window.start.hour * 60 + window.start.minute
        let endMinutes = window.end.hour * 60 + window.end.minute
        let target = max(startMinutes, endMinutes - max(0, leadMinutes))
        return ClockTime(hour: target / 60, minute: target % 60)
    }

    private func lastDayOfMonth(for day: Date, calendar: Calendar) -> Int {
        calendar.range(of: .day, in: .month, for: day)?.count ?? 28
    }

    private static let occurrenceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
