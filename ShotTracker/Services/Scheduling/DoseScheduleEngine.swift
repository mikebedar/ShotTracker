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
    /// The `DailyTiming.id` this occurrence came from.
    var timingID: UUID? = nil
    /// The zone this occurrence's clock times are on when it isn't the regimen's home
    /// zone (a slot that follows the device while travelling); nil = home.
    var clockTimeZoneIdentifier: String? = nil

    /// The window end, or a precise dose's time plus its grace (`ScheduledDose.windowEnd`).
    var windowEnd: Date {
        windowEndAt ?? scheduledAt.addingTimeInterval(TimeInterval(graceWindowMinutes * 60))
    }
}

/// The slot a rolling (`.rescheduleFromLastDose`) regimen's last real dose occupied on
/// its day. Later slots that day still happen: taking the morning dose of a twice-daily
/// injection must not erase that evening's dose.
struct RollingAnchorSlot: Hashable {
    let timingID: UUID?
    let timingLabel: String
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
    let timingID: UUID
}

final class DoseScheduleEngine {
    /// Which zone counts as "where the device is" for timings that follow it.
    enum DeviceClock {
        /// `TimeZone.current` at generation time (the app; `-deviceTimeZone` sets it).
        case system
        /// A fixed zone (tests: "the phone is in Paris").
        case fixed(TimeZone)
        /// The device is always at each schedule's home — no travel. Tests that predate
        /// travelling slots use this so they read the same on any host zone.
        case atHome
    }

    let deviceClock: DeviceClock

    init(deviceClock: DeviceClock = .system) {
        self.deviceClock = deviceClock
    }

    /// The device's zone for a schedule whose home is `home`.
    func deviceTimeZone(home: TimeZone) -> TimeZone {
        switch deviceClock {
        case .system: .current
        case .fixed(let zone): zone
        case .atHome: home
        }
    }

    /// A clock occurrences are generated on: the regimen's home calendar, or — while the
    /// device is in another zone — the device's, for the timings that follow it.
    private struct GenerationClock {
        let calendar: Calendar
        /// nil = the home zone (keys and rows carry nothing extra).
        let zoneIdentifier: String?
        let includes: (DailyTiming) -> Bool
    }

    /// Everything a medication's current regimen generates in a range: the missed-dose
    /// policy's inputs (`DoseRescheduling.engineInputs`) applied. Both tiers (the
    /// materialized window and the forecast) call this, so they always agree.
    func generateOccurrences(
        for medication: Medication,
        regimen: MedicationRegimen,
        from startDate: Date,
        through endDate: Date,
        preferences: AppPreferences
    ) -> [GeneratedDoseOccurrence] {
        let inputs = DoseRescheduling.engineInputs(for: medication, regimen: regimen)
        return generateOccurrences(
            for: regimen,
            medicationID: medication.id,
            from: startDate,
            through: endDate,
            preferences: preferences,
            anchorOverride: inputs.anchor,
            rollingInterval: inputs.rollingInterval,
            notBefore: inputs.notBefore,
            rollingAnchorSlot: inputs.rollingAnchorSlot,
            floorDay: inputs.floorDay
        )
    }

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
    /// - `floorDay`: occurrences on days before the day containing this instant are
    ///   excluded, the day read on each occurrence's own clock (a version's creation day:
    ///   `DoseRescheduling.fixedGenerationFloor`).
    ///
    /// **Travel (decided 2026-10-23).** Timings that follow the device
    /// (`MedicationRegimen.travelPolicy(for:)`: named slots by default) are generated on
    /// the device's clock when it is in another zone than the regimen's home: the slot's
    /// window in local time, on the same calendar dates (the anchor's home date is the
    /// local anchor date). Their keys and rows carry the zone (`@Europe/Paris`,
    /// `clockTimeZoneIdentifier`). Timings that stay home are generated on the home clock
    /// as before. At home both are the home clock and nothing changes.
    func generateOccurrences(
        for regimen: MedicationRegimen,
        medicationID: UUID,
        from startDate: Date,
        through endDate: Date,
        preferences: AppPreferences,
        anchorOverride: Date? = nil,
        rollingInterval: DateComponents? = nil,
        notBefore: Date? = nil,
        rollingAnchorSlot: RollingAnchorSlot? = nil,
        floorDay: Date? = nil
    ) -> [GeneratedDoseOccurrence] {
        let home = regimen.homeTimeZone
        var homeCalendar = Calendar(identifier: .gregorian)
        homeCalendar.timeZone = home
        let device = deviceTimeZone(home: home)

        let clocks: [GenerationClock]
        if device.identifier == home.identifier {
            clocks = [GenerationClock(calendar: homeCalendar, zoneIdentifier: nil, includes: { _ in true })]
        } else {
            var deviceCalendar = Calendar(identifier: .gregorian)
            deviceCalendar.timeZone = device
            clocks = [
                GenerationClock(calendar: homeCalendar, zoneIdentifier: nil, includes: { regimen.travelPolicy(for: $0) == .staysOnHome }),
                GenerationClock(calendar: deviceCalendar, zoneIdentifier: device.identifier, includes: { regimen.travelPolicy(for: $0) == .followsMe }),
            ]
        }

        return clocks
            .flatMap { clock in
                occurrences(
                    on: clock, homeCalendar: homeCalendar, regimen: regimen, medicationID: medicationID,
                    from: startDate, through: endDate, preferences: preferences,
                    anchorOverride: anchorOverride, rollingInterval: rollingInterval,
                    notBefore: notBefore, rollingAnchorSlot: rollingAnchorSlot, floorDay: floorDay
                )
            }
            .sorted { $0.scheduledAt == $1.scheduledAt ? $0.occurrenceKey < $1.occurrenceKey : $0.scheduledAt < $1.scheduledAt }
    }

    private func occurrences(
        on clock: GenerationClock,
        homeCalendar: Calendar,
        regimen: MedicationRegimen,
        medicationID: UUID,
        from startDate: Date,
        through endDate: Date,
        preferences: AppPreferences,
        anchorOverride: Date?,
        rollingInterval: DateComponents?,
        notBefore: Date?,
        rollingAnchorSlot: RollingAnchorSlot?,
        floorDay: Date?
    ) -> [GeneratedDoseOccurrence] {
        let calendar = clock.calendar
        let startDay = calendar.startOfDay(for: min(startDate, endDate))
        let endDay = calendar.startOfDay(for: max(startDate, endDate))
        let anchorDay: Date
        if clock.zoneIdentifier == nil {
            anchorDay = calendar.startOfDay(for: anchorOverride ?? regimen.anchorDate)
        } else if rollingInterval != nil, let notBefore {
            // A rolling schedule counts from the local day the last dose was taken on.
            anchorDay = calendar.startOfDay(for: notBefore)
        } else {
            // The schedule's start date is a calendar date: the same date here.
            anchorDay = Self.sameDate(as: anchorOverride ?? regimen.anchorDate, from: homeCalendar, in: calendar)
        }

        let occurrences: [GeneratedDoseOccurrence]
        if let rollingInterval {
            occurrences = rollingOccurrences(
                for: regimen, medicationID: medicationID, interval: rollingInterval,
                anchorDay: anchorDay, startDay: startDay, endDay: endDay,
                clock: clock, preferences: preferences, anchorSlot: rollingAnchorSlot
            )
        } else {
            occurrences = matchedOccurrences(
                for: regimen, medicationID: medicationID,
                anchorDay: anchorDay, startDay: startDay, endDay: endDay,
                clock: clock, preferences: preferences
            )
        }

        let floor = floorDay.map { calendar.startOfDay(for: $0) }
        return occurrences.filter { occurrence in
            if let notBefore, occurrence.scheduledAt <= notBefore { return false }
            if let floor, occurrence.scheduledAt < floor { return false }
            return true
        }
    }

    /// Midnight, on `target`'s clock, of the calendar date `date` falls on in `source`.
    static func sameDate(as date: Date, from source: Calendar, in target: Calendar) -> Date {
        let components = source.dateComponents([.year, .month, .day], from: date)
        return target.date(from: DateComponents(
            timeZone: target.timeZone, year: components.year, month: components.month, day: components.day
        )) ?? target.startOfDay(for: date)
    }

    private func matchedOccurrences(
        for regimen: MedicationRegimen,
        medicationID: UUID,
        anchorDay: Date,
        startDay: Date,
        endDay: Date,
        clock: GenerationClock,
        preferences: AppPreferences
    ) -> [GeneratedDoseOccurrence] {
        let calendar = clock.calendar
        var occurrences: [GeneratedDoseOccurrence] = []
        var cursor = max(startDay, anchorDay)

        while cursor <= endDay {
            let daysFromAnchor = calendar.dateComponents([.day], from: anchorDay, to: cursor).day ?? 0

            guard daysFromAnchor >= 0 else {
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
                continue
            }

            let phase = activePhase(for: daysFromAnchor, regimen: regimen)
            // A phased regimen doses only inside its phases: once the last finite phase
            // ends (a finished taper) there's nothing more to take. It used to fall back
            // to the regimen's own `.phased` rule, which matches every day — so a 10-day
            // prednisone taper went on daily forever.
            if regimen.recurrenceRule.frequency == .phased, phase == nil {
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
                continue
            }
            let rule = phase?.recurrenceRule ?? regimen.recurrenceRule
            let timings = phase?.timings.isEmpty == false ? phase?.timings ?? [] : regimen.timings
            // A phase's own interval counts from the phase's first day, not the regimen's.
            let ruleOffset = daysFromAnchor - (phase?.startDayOffset ?? 0)

            if matches(rule: rule, on: cursor, anchorDay: anchorDay, dayOffset: ruleOffset, calendar: calendar) {
                occurrences.append(contentsOf: makeOccurrences(on: cursor, timings: timings, regimen: regimen, medicationID: medicationID, clock: clock, preferences: preferences))
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
        clock: GenerationClock,
        preferences: AppPreferences,
        anchorSlot: RollingAnchorSlot?
    ) -> [GeneratedDoseOccurrence] {
        let calendar = clock.calendar
        var occurrences: [GeneratedDoseOccurrence] = []
        var cursor = anchorDay
        var guardCounter = 0

        // The anchor day itself: only the slots that come after the one the last dose
        // filled (none when that slot can't be identified, e.g. after a timing edit).
        if let anchorSlot, anchorDay >= startDay, anchorDay <= endDay {
            let ordered = resolveTimings(regimen.timings, preferences: preferences)
                .sorted { ($0.start.hour * 60 + $0.start.minute) < ($1.start.hour * 60 + $1.start.minute) }
            let takenIndex = ordered.firstIndex { timing in
                if let id = anchorSlot.timingID { return timing.timingID == id }
                return timing.label == anchorSlot.timingLabel
            } ?? ordered.firstIndex { $0.label == anchorSlot.timingLabel }
            if let takenIndex {
                let mine = Set(resolveTimings(regimen.timings, preferences: preferences, includes: clock.includes).map(\.timingID))
                let later: [ResolvedTiming]
                if mine.contains(ordered[takenIndex].timingID) {
                    later = ordered[(takenIndex + 1)...].filter { mine.contains($0.timingID) }
                } else {
                    // The last dose was on the other clock (travelling): this clock's slots
                    // that day all count, after the dose itself (`notBefore`).
                    later = ordered.filter { mine.contains($0.timingID) }
                }
                occurrences.append(contentsOf: makeOccurrences(on: anchorDay, resolved: later, regimen: regimen, medicationID: medicationID, clock: clock))
            }
        }

        while cursor <= endDay {
            guardCounter += 1
            if guardCounter > 10_000 { break }  // safety against a zero/negative interval

            guard let next = calendar.date(byAdding: interval, to: cursor), next > cursor else { break }
            cursor = next

            guard cursor >= startDay else { continue }
            occurrences.append(contentsOf: makeOccurrences(on: cursor, timings: regimen.timings, regimen: regimen, medicationID: medicationID, clock: clock, preferences: preferences))
        }

        return occurrences
    }

    private func makeOccurrences(
        on day: Date,
        timings: [DailyTiming],
        regimen: MedicationRegimen,
        medicationID: UUID,
        clock: GenerationClock,
        preferences: AppPreferences
    ) -> [GeneratedDoseOccurrence] {
        makeOccurrences(
            on: day,
            resolved: resolveTimings(timings, preferences: preferences, includes: clock.includes),
            regimen: regimen,
            medicationID: medicationID,
            clock: clock
        )
    }

    private func makeOccurrences(
        on day: Date,
        resolved: [ResolvedTiming],
        regimen: MedicationRegimen,
        medicationID: UUID,
        clock: GenerationClock
    ) -> [GeneratedDoseOccurrence] {
        let calendar = clock.calendar
        return resolved.map { timing in
            let scheduledAt = timing.start.applying(to: day, calendar: calendar)
            let occurrenceKey = Self.occurrenceKey(
                medicationID: medicationID, version: regimen.version,
                scheduledAt: scheduledAt, label: timing.label, calendar: calendar,
                clockTimeZoneIdentifier: clock.zoneIdentifier
            )

            return GeneratedDoseOccurrence(
                occurrenceKey: occurrenceKey,
                scheduledAt: scheduledAt,
                windowEndAt: timing.isWindow ? timing.end.applying(to: day, calendar: calendar) : nil,
                reminderAt: timing.reminder.applying(to: day, calendar: calendar),
                timingLabel: timing.label,
                reminderWindowMinutes: timing.reminderWindowMinutes,
                graceWindowMinutes: regimen.graceWindowMinutes,
                timingID: timing.timingID,
                clockTimeZoneIdentifier: clock.zoneIdentifier
            )
        }
    }

    /// `"{medicationID}-v{version}-{yyyyMMddHHmm}-{label}"`, with the date read in the
    /// generating calendar (the regimen's home zone). A formatter in the device's current
    /// zone made every key change when the user travelled, re-materializing doses already
    /// taken. A slot generated on the device's clock while travelling ends in
    /// `@{zone}` ("…-202610230600-morning@Europe/Paris"): its wall-clock stamp alone would
    /// collide with the home dose of the same date and time, a different instant.
    static func occurrenceKey(
        medicationID: UUID,
        version: Int,
        scheduledAt: Date,
        label: String,
        calendar: Calendar,
        clockTimeZoneIdentifier: String? = nil
    ) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: scheduledAt)
        let stamp = String(format: "%04d%02d%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        let key = "\(medicationID.uuidString)-v\(version)-\(stamp)-\(label)"
        return clockTimeZoneIdentifier.map { key + "@" + $0 } ?? key
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

    private func resolveTimings(
        _ timings: [DailyTiming],
        preferences: AppPreferences,
        includes: (DailyTiming) -> Bool = { _ in true }
    ) -> [ResolvedTiming] {
        let source = (timings.isEmpty ? [Self.fallbackTiming] : timings).filter(includes)

        return source.map { timing in
            let label = timing.slotLabel

            if timing.kind == .exactTime {
                // A precise point: window collapses to the single time, remind at it.
                let time = timing.exactTime ?? timing.overrideTime ?? ClockTime(hour: 8, minute: 0)
                return ResolvedTiming(
                    label: label, start: time, end: time, reminder: time,
                    isWindow: false, reminderWindowMinutes: max(15, timing.reminderWindowMinutes),
                    timingID: timing.id
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
                isWindow: true, reminderWindowMinutes: max(15, timing.reminderWindowMinutes),
                timingID: timing.id
            )
        }
    }

    /// Used when a regimen has no timings; a fixed id keeps its doses' identity stable.
    static let fallbackTiming = DailyTiming(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000F00D")!,
        kind: .morning
    )

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

}
