import Foundation

/// "How this schedule works" (decided 2026-10-23, branch `travel-options`): a short,
/// plain-language account of a schedule generated from its values — when doses are on
/// time, what happens when one is late, reminders and snooze, and travel. Shown in the
/// confirmation step when a new or changed schedule is saved and on the medication's
/// detail screen. Every sentence reads the same values the engine, the notification
/// planner and the reconciliation use.
struct ScheduleSummary: Equatable {
    struct Line: Equatable, Identifiable {
        enum Topic: String {
            case timing, missed, reminders, travel
        }
        let topic: Topic
        let title: String
        let text: String
        var id: String { topic.rawValue }
    }

    /// A schedule as plain values (from the edit form's draft or a saved regimen).
    struct Inputs {
        var timings: [DailyTiming]
        var rule: RecurrenceRule
        /// For a phased schedule, one entry per phase ("Loading: daily, 5 days").
        var phaseSteps: [String] = []
        var graceWindowMinutes: Int
        var missedDosePolicy: MissedDosePolicy
        var minimumIntervalHours: Int
        var home: TimeZone
        var travel: TravelSettings
        var remindersEnabled = true
        var dueRemindersEnabled = true
        var overdueRemindersEnabled = true
        var escalationIntervalsMinutes: [Int] = [0, 30, 120, 720, 1440]
        var maxReminderCount = 6
        var allowSnooze = true
        var snoozeMinutes = 20
    }

    let lines: [Line]

    init(_ inputs: Inputs, preferences: AppPreferences, locale: Locale = .current) {
        let words = SummaryWords(locale: locale)
        lines = [
            Line(topic: .timing, title: String(localized: "When", comment: "Schedule summary: timing heading"), text: words.timing(inputs, preferences: preferences)),
            Line(topic: .missed, title: String(localized: "If you're late", comment: "Schedule summary: missed-dose heading"), text: words.missed(inputs)),
            Line(topic: .reminders, title: String(localized: "Reminders and snooze", comment: "Schedule summary: reminders heading"), text: words.reminders(inputs, preferences: preferences)),
            Line(topic: .travel, title: String(localized: "When you travel", comment: "Schedule summary: travel heading"), text: words.travel(inputs)),
        ]
    }

    /// All of it as one paragraph per topic ("When: …").
    var text: String {
        lines.map { "\($0.title): \($0.text)" }.joined(separator: "\n")
    }
}

extension ScheduleSummary.Inputs {
    /// A saved schedule: the regimen and its newest reminder policy.
    init(regimen: MedicationRegimen) {
        let policy = regimen.activeReminderPolicy ?? ReminderPolicy()
        self.init(
            timings: regimen.timings.isEmpty ? [DoseScheduleEngine.fallbackTiming] : regimen.timings,
            rule: regimen.recurrenceRule,
            phaseSteps: ScheduleSummary.phaseSteps(regimen.phases.sorted { $0.startDayOffset < $1.startDayOffset }.map {
                ($0.title, $0.recurrenceRule, $0.durationDays)
            }),
            graceWindowMinutes: regimen.graceWindowMinutes,
            missedDosePolicy: regimen.missedDosePolicy,
            minimumIntervalHours: regimen.effectiveMinimumIntervalHours,
            home: regimen.homeTimeZone,
            travel: regimen.travelSettings,
            remindersEnabled: policy.isEnabled,
            dueRemindersEnabled: policy.dueRemindersEnabled,
            overdueRemindersEnabled: policy.overdueRemindersEnabled,
            escalationIntervalsMinutes: policy.escalationIntervalsMinutes,
            maxReminderCount: policy.maxReminderCount,
            allowSnooze: policy.allowSnooze,
            snoozeMinutes: policy.defaultSnoozeMinutes
        )
    }
}

extension ScheduleSummary {
    /// "Loading: daily, 5 days" per phase.
    static func phaseSteps(_ phases: [(title: String, rule: RecurrenceRule, days: Int?)]) -> [String] {
        phases.map { phase in
            let cadence = phase.rule.frequency == .intervalDays
                ? String(localized: "every \(phase.rule.intervalDays) days", comment: "Schedule summary: a phase's cadence")
                : String(localized: "daily", comment: "Schedule summary: a phase's cadence")
            let length = phase.days.map { $0 == 1 ? String(localized: "1 day", comment: "Schedule summary: a phase's length") : String(localized: "\($0) days", comment: "Schedule summary: a phase's length") }
                ?? String(localized: "then ongoing", comment: "Schedule summary: the last phase has no end")
            return "\(phase.title): \(cadence), \(length)"
        }
    }
}

private struct SummaryWords {
    let locale: Locale

    func duration(minutes: Int) -> String {
        if minutes % 1440 == 0, minutes >= 1440 {
            let days = minutes / 1440
            return days == 1 ? String(localized: "1 day", comment: "Duration") : String(localized: "\(days) days", comment: "Duration")
        }
        if minutes % 60 == 0, minutes >= 60 {
            let hours = minutes / 60
            return hours == 1 ? String(localized: "1 hour", comment: "Duration") : String(localized: "\(hours) hours", comment: "Duration")
        }
        return String(localized: "\(minutes) min", comment: "Duration in minutes")
    }

    func list(_ items: [String]) -> String {
        items.formatted(.list(type: .and).locale(locale))
    }

    func clock(_ time: ClockTime) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return time.displayText(calendar: calendar, locale: locale)
    }

    func cadence(_ inputs: ScheduleSummary.Inputs) -> String {
        let rule = inputs.rule
        switch rule.frequency {
        case .daily:
            return String(localized: "Every day", comment: "Schedule summary: daily")
        case .intervalDays:
            return String(localized: "Every \(rule.intervalDays) days", comment: "Schedule summary: every N days")
        case .weekly:
            let days = rule.weekdays.map(AppFormatting.weekdayTitle)
            return days.isEmpty
                ? String(localized: "Every week", comment: "Schedule summary: weekly")
                : String(localized: "Every week on \(list(days))", comment: "Schedule summary: weekly on days")
        case .monthly:
            return String(localized: "Every month on day \(rule.dayOfMonth)", comment: "Schedule summary: monthly")
        case .cycle:
            return String(localized: "\(rule.cycleOnDays) days on, \(rule.cycleOffDays) days off", comment: "Schedule summary: a cycle")
        case .phased:
            return inputs.phaseSteps.isEmpty
                ? String(localized: "In phases", comment: "Schedule summary: phased")
                : String(localized: "In phases (\(inputs.phaseSteps.joined(separator: " → ")))", comment: "Schedule summary: phased, with its steps")
        }
    }

    func window(of timing: DailyTiming, preferences: AppPreferences) -> DoseWindow? {
        guard timing.kind.isWindow else { return nil }
        return timing.customWindow ?? preferences.defaultSlotWindows[timing.kind.rawValue] ?? timing.kind.defaultWindow
    }

    func timing(_ inputs: ScheduleSummary.Inputs, preferences: AppPreferences) -> String {
        let parts = inputs.timings.map { timing -> String in
            if let window = window(of: timing, preferences: preferences) {
                return String(localized: "\(timing.kind.title) anytime \(clock(window.start))–\(clock(window.end))", comment: "Schedule summary: a slot and its window")
            }
            let time = timing.exactTime ?? timing.overrideTime ?? ClockTime(hour: 8, minute: 0)
            return String(localized: "\(clock(time)), on time for \(duration(minutes: inputs.graceWindowMinutes)) after", comment: "Schedule summary: a specific time and its grace")
        }
        return String(localized: "\(cadence(inputs)): \(list(parts)). Taking a dose early or anywhere in its window counts as on time.", comment: "Schedule summary: when doses are on time")
    }

    func missed(_ inputs: ScheduleSummary.Inputs) -> String {
        let rolls = inputs.missedDosePolicy == .rescheduleFromLastDose
            && [.daily, .intervalDays, .weekly, .monthly].contains(inputs.rule.frequency)
        switch inputs.missedDosePolicy {
        case .rescheduleFromLastDose where rolls:
            let interval: String
            switch inputs.rule.frequency {
            case .daily: interval = String(localized: "a day", comment: "Schedule summary: interval")
            case .intervalDays: interval = String(localized: "\(inputs.rule.intervalDays) days", comment: "Schedule summary: interval")
            case .weekly: interval = String(localized: "a week", comment: "Schedule summary: interval")
            default: interval = String(localized: "a month", comment: "Schedule summary: interval")
            }
            return String(localized: "Each dose sets the next one: it comes \(interval) after you actually take it. You'll get a heads-up if you log one sooner than \(duration(minutes: inputs.minimumIntervalHours * 60)) after the last.", comment: "Schedule summary: rescheduling from the last dose")
        case .skipIfLate:
            return String(localized: "Once a window closes, that dose counts as missed; wait for the next scheduled one rather than making it up.", comment: "Schedule summary: skip if late")
        default:
            return String(localized: "After its window closes a dose shows as overdue and can still be logged late until a later dose replaces it; the next dose stays on its usual day.", comment: "Schedule summary: keep to schedule")
        }
    }

    func reminders(_ inputs: ScheduleSummary.Inputs, preferences: AppPreferences) -> String {
        var parts: [String] = []
        if !inputs.remindersEnabled || !preferences.globalNotificationsEnabled {
            parts.append(String(localized: "No reminders.", comment: "Schedule summary: reminders off"))
        } else {
            var intervals = inputs.escalationIntervalsMinutes
            if !preferences.globalDueRemindersEnabled || !inputs.dueRemindersEnabled { intervals.removeAll { $0 == 0 } }
            if !preferences.globalOverdueRemindersEnabled || !inputs.overdueRemindersEnabled { intervals = intervals.filter { $0 == 0 } }
            let fired = Array(intervals.prefix(inputs.maxReminderCount))
            let hasWindow = inputs.timings.contains { $0.kind.isWindow }
            let first = hasWindow
                ? String(localized: "A reminder comes \(duration(minutes: preferences.windowReminderLeadMinutes)) before a window closes (at the time itself for a specific time)", comment: "Schedule summary: when the first reminder comes")
                : String(localized: "A reminder comes at the dose's time", comment: "Schedule summary: when the first reminder comes, specific times")
            let followUps = fired.filter { $0 > 0 }.map { duration(minutes: $0) }
            if fired.isEmpty {
                parts.append(String(localized: "No reminders.", comment: "Schedule summary: reminders off"))
            } else if followUps.isEmpty {
                parts.append(first + ".")
            } else if fired.contains(0) {
                parts.append(String(localized: "\(first), then again after \(list(followUps)) until you log it.", comment: "Schedule summary: reminders with follow-ups"))
            } else {
                parts.append(String(localized: "Reminders come \(list(followUps)) after the reminder time until you log it.", comment: "Schedule summary: overdue reminders only"))
            }
        }
        parts.append(inputs.allowSnooze
            ? String(localized: "Snooze moves only this dose's reminder and deadline, \(duration(minutes: inputs.snoozeMinutes)) each time; on time is still judged by the usual window.", comment: "Schedule summary: snooze")
            : String(localized: "Snooze is off for this medication.", comment: "Schedule summary: no snooze"))
        return parts.joined(separator: " ")
    }

    func travel(_ inputs: ScheduleSummary.Inputs) -> String {
        let travel = inputs.travel
        let homePlace = SlotClockLabel.placeName(of: inputs.home)
        let following = inputs.timings.filter { travel.clock(for: $0) == .followsMe }
        guard !following.isEmpty else {
            return String(localized: "Doses stay on \(homePlace) time wherever you are: reminders come at that moment and both clocks are shown. Long flights never move a dose.", comment: "Schedule summary: kept on home time")
        }
        let names = list(following.map { $0.kind == .exactTime ? clock($0.exactTime ?? ClockTime(hour: 8, minute: 0)) : $0.kind.title })
        var sentences: [String] = []
        if following.count == inputs.timings.count {
            sentences.append(following.count == 1
                ? String(localized: "\(names) follows the local clock wherever you are, with home time shown too.", comment: "Schedule summary: one slot that follows you")
                : String(localized: "\(names) follow the local clock wherever you are, with home time shown too.", comment: "Schedule summary: slots that follow you"))
        } else {
            sentences.append(following.count == 1
                ? String(localized: "\(names) follows the local clock; specific times stay on \(homePlace) time.", comment: "Schedule summary: a mix of following and home times, one following")
                : String(localized: "\(names) follow the local clock; specific times stay on \(homePlace) time.", comment: "Schedule summary: a mix of following and home times"))
        }
        switch travel.spacing {
        case .calendarDay:
            sentences.append(String(localized: "One of each per calendar day where you are, so after a long flight east two doses can be closer than usual.", comment: "Schedule summary: calendar-day spacing"))
        case .minimumHours:
            sentences.append(String(localized: "After a time zone change the next one waits until at least \(travel.minimumHours) hours after the last, whatever the date.", comment: "Schedule summary: minimum hours spacing"))
        }
        switch travel.landing {
        case .finishOnOldClock:
            sentences.append(String(localized: "A dose open when the time zone changes finishes on the old clock.", comment: "Schedule summary: finishing on the old clock"))
        case .moveNow:
            sentences.append(String(localized: "A dose open when the time zone changes moves to the local clock at once.", comment: "Schedule summary: moving to the new clock"))
        }
        return sentences.joined(separator: " ")
    }
}
