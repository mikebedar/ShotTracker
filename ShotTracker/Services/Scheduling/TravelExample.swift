import Foundation

/// The live example under "When you travel" (decided 2026-10-23, branch `travel-options`):
/// what the schedule being edited does on a hypothetical trip from home to `destination`,
/// computed by the real engine and reconciliation (`DoseReconciliation.refreshPlan`) over
/// simulated doses — never hand-written outcomes. The words are templates; every time,
/// gap and "you get another dose / you don't" comes from the simulation.
///
/// Two trips are simulated with the first timing that follows the device (else the first
/// timing):
/// - **The long flight**: take that dose on its next dosing day (a window: two hours after
///   it opens, at most half an hour before it closes; a specific time: at it), leave an
///   hour later, land after `flightHours` (the time difference plus two, 3–15 hours), and
///   re-plan on the destination clock. Reports the next dose of that slot: when it opens,
///   on which clock, how many hours after the one taken, and whether the destination's
///   same calendar day (still open at landing) gets one.
/// - **Landing during a dose**: nothing taken that day; the phone changes zone halfway
///   through that dose's window at home. Reports where the open dose went (kept on the
///   old clock, moved, late) and, when kept, what happens once its old window closes.
struct TravelExample: Equatable {
    /// "If you fly from New York to Paris (6 hours ahead):"
    let heading: String
    /// One sentence per choice, in the section's order (clock, long trips, landing).
    let lines: [String]
    let facts: Facts

    struct Facts: Equatable {
        var follows: Bool
        var landedAt: Date?
        var flightHours: Int?
        /// The next dose of the slot after the one taken before the flight.
        var nextStart: Date?
        var nextEnd: Date?
        var nextClock: String?
        var nextHeldHours: Int?
        var hoursAfterLast: Int?
        /// The destination's same-day window of the slot was still open (or ahead) at landing.
        var sameDayWindowOpenAtLanding = false
        /// …and a dose of the slot was offered on it.
        var offeredSameDay = false
        /// Landing during a dose: the open dose's clock (nil = home) and window after the switch.
        var landingSwitchAt: Date?
        var landingClock: String?
        var landingStart: Date?
        var landingEnd: Date?
        var landingStatusAtSwitch: DoseStatus?
        /// When kept on the old clock: where it is once that window has closed (nil = stayed).
        var landingLaterClock: String?
        var landingLaterEnd: Date?
    }

    /// The schedule as plain values (the draft's, or a regimen's).
    struct Schedule {
        var timings: [DailyTiming]
        var rule: RecurrenceRule
        var anchorDate: Date
        var graceWindowMinutes: Int
        var missedDosePolicy: MissedDosePolicy
        var home: TimeZone
        var travel: TravelSettings
    }

    /// Hours of flying the example assumes: the time difference plus two, 3–15 hours
    /// (New York → Paris 8, → Tokyo 15, → Los Angeles 5).
    static func flightHours(from home: TimeZone, to destination: TimeZone, at date: Date) -> Int {
        let difference = abs(destination.secondsFromGMT(for: date) - home.secondsFromGMT(for: date)) / 3600
        return min(15, max(3, difference + 2))
    }

    static func make(
        schedule: Schedule,
        destination: TimeZone,
        preferences: AppPreferences,
        from start: Date,
        locale: Locale = .current
    ) -> TravelExample? {
        let home = schedule.home
        let regimen = MedicationRegimen(
            version: 1,
            anchorDate: schedule.anchorDate,
            timeZoneIdentifier: home.identifier,
            recurrenceRule: schedule.rule.frequency == .phased ? RecurrenceRule(frequency: .daily) : schedule.rule,
            timings: schedule.timings.isEmpty ? [DoseScheduleEngine.fallbackTiming] : schedule.timings,
            graceWindowMinutes: schedule.graceWindowMinutes,
            createdAt: min(schedule.anchorDate, start),
            missedDosePolicy: schedule.missedDosePolicy,
            travelPolicy: schedule.travel.clock,
            travelSpacing: schedule.travel.spacing,
            travelMinimumHours: schedule.travel.minimumHours,
            travelLanding: schedule.travel.landing
        )
        let medicationID = UUID(uuidString: "00000000-0000-0000-0000-0000000E4A3F")!
        let words = Words(home: home, destination: destination, locale: locale)

        // The slot the example follows, and its next dose at home.
        let atHome = DoseScheduleEngine(deviceClock: .atHome)
        let homeOccurrences = atHome.generateOccurrences(
            for: regimen, medicationID: medicationID,
            from: start, through: start.addingTimeInterval(62 * 86_400), preferences: preferences
        ).filter { $0.scheduledAt >= start }
        let following = regimen.timings.filter { regimen.travelPolicy(for: $0) == .followsMe }
        let candidates = following.isEmpty ? regimen.timings : following
        guard let departure = homeOccurrences.first(where: { occurrence in candidates.contains { $0.id == occurrence.timingID } }),
              let timing = regimen.timings.first(where: { $0.id == departure.timingID })
        else { return nil }
        let follows = regimen.travelPolicy(for: timing) == .followsMe
        let slotName = SlotTitle.title(label: departure.timingLabel, scheduledAt: departure.scheduledAt, isWindow: departure.windowEndAt != nil, timeZone: home)
        let doseName = String(localized: "\(slotName) dose", comment: "Travel example: the dose of a slot, e.g. Morning dose")
        // In a sentence: "the morning dose", "the 8:00 AM dose".
        let theDose = departure.windowEndAt == nil
            ? String(localized: "the \(doseName)", comment: "Travel example: a specific time's dose in a sentence")
            : String(localized: "the \(doseName.lowercased(with: locale))", comment: "Travel example: a slot's dose in a sentence")
        let difference = destination.secondsFromGMT(for: departure.scheduledAt) - home.secondsFromGMT(for: departure.scheduledAt)
        let heading = words.heading(difference: difference)
        var facts = Facts(follows: follows)

        guard difference != 0 else {
            return TravelExample(
                heading: heading,
                lines: [String(localized: "Both places keep the same time, so nothing about \(theDose) changes.", comment: "Travel example: no time difference")],
                facts: facts
            )
        }

        // The clock, on an ordinary dosing day there (the next one after the departure
        // dose, generated without any trip history).
        let away = DoseScheduleEngine(deviceClock: .fixed(destination))
        // The departure date there, so the times match the heading's time difference.
        var homeCalendar = Calendar(identifier: .gregorian)
        homeCalendar.timeZone = home
        var awayCalendar = Calendar(identifier: .gregorian)
        awayCalendar.timeZone = destination
        let departureDate = homeCalendar.dateComponents([.year, .month, .day], from: departure.scheduledAt)
        let around = away.generateOccurrences(
            for: regimen, medicationID: medicationID,
            from: departure.scheduledAt.addingTimeInterval(-2 * 86_400), through: departure.scheduledAt.addingTimeInterval(40 * 86_400), preferences: preferences
        ).filter { $0.timingID == timing.id }
        let steady = around.first {
            let date = awayCalendar.dateComponents([.year, .month, .day], from: $0.scheduledAt)
            return date.year == departureDate.year && date.month == departureDate.month && date.day == departureDate.day
        } ?? around.first { $0.scheduledAt >= departure.scheduledAt }
        var lines: [String] = []
        if let steady {
            lines.append(words.clockLine(doseName: doseName, occurrence: steady, follows: follows, mixed: !following.isEmpty && following.count < regimen.timings.count))
        }

        guard follows else {
            lines.append(String(localized: "Because it stays on home time, long flights never bring two doses closer together, and a dose that's open when you land keeps its time.", comment: "Travel example: a medication kept on home time"))
            return TravelExample(heading: heading, lines: lines, facts: facts)
        }

        // 1. The long flight.
        let takenAt: Date
        if let end = departure.windowEndAt {
            takenAt = min(departure.scheduledAt.addingTimeInterval(2 * 3600), end.addingTimeInterval(-30 * 60))
        } else {
            takenAt = departure.scheduledAt
        }
        let hours = flightHours(from: home, to: destination, at: takenAt)
        let landed = takenAt.addingTimeInterval(TimeInterval((hours + 1) * 3600))
        var trip = TripSimulation(regimen: regimen, medicationID: medicationID, preferences: preferences)
        trip.refresh(at: departure.scheduledAt.addingTimeInterval(-60), device: home)
        trip.take(key: departure.occurrenceKey, at: takenAt)
        trip.refresh(at: takenAt, device: home)
        trip.refresh(at: landed, device: destination)
        facts.landedAt = landed
        facts.flightHours = hours

        var destinationCalendar = Calendar(identifier: .gregorian)
        destinationCalendar.timeZone = destination
        let sameDayWindow = away.generateOccurrences(
            for: regimen, medicationID: medicationID,
            from: landed.addingTimeInterval(-86_400), through: landed.addingTimeInterval(86_400), preferences: preferences
        ).first { $0.timingID == timing.id && destinationCalendar.isDate($0.scheduledAt, inSameDayAs: landed) }
        facts.sameDayWindowOpenAtLanding = (sameDayWindow?.windowEnd ?? .distantPast) > landed
        if let next = trip.doses
            .filter({ $0.timingID == timing.id && $0.completedAt == nil && $0.windowEnd > landed })
            .min(by: { $0.scheduledAt < $1.scheduledAt }) {
            facts.nextStart = next.scheduledAt
            facts.nextEnd = next.windowEnd
            facts.nextClock = next.clockTimeZoneIdentifier
            facts.nextHeldHours = next.spacingHoldHours
            facts.hoursAfterLast = Int((next.scheduledAt.timeIntervalSince(takenAt) / 3600).rounded())
            facts.offeredSameDay = destinationCalendar.isDate(next.scheduledAt, inSameDayAs: landed)
            let usual = away.generateOccurrences(
                for: regimen, medicationID: medicationID,
                from: next.scheduledAt.addingTimeInterval(-2 * 86_400), through: next.scheduledAt.addingTimeInterval(2 * 86_400), preferences: preferences
            ).first { $0.occurrenceKey == next.occurrenceKey }?.scheduledAt
            lines.append(words.flightLine(
                slotName: slotName, takenAt: takenAt, flightHours: hours, landed: landed,
                next: next, usualStart: usual, facts: facts, spacing: schedule.travel.spacing,
                usualGap: TravelSettings.nominalHours(for: regimen.recurrenceRule)
            ))
        }

        // 2. Landing during a dose.
        do {
            let end = departure.windowEnd
            let switchAt = departure.scheduledAt.addingTimeInterval(end.timeIntervalSince(departure.scheduledAt) / 2)
            var landing = TripSimulation(regimen: regimen, medicationID: medicationID, preferences: preferences)
            landing.refresh(at: departure.scheduledAt.addingTimeInterval(-60), device: home)
            let openID = landing.idForKey[departure.occurrenceKey]
            landing.refresh(at: switchAt, device: destination)
            if let open = landing.doses.first(where: { $0.id == openID }) {
                facts.landingSwitchAt = switchAt
                facts.landingClock = open.clockTimeZoneIdentifier
                facts.landingStart = open.scheduledAt
                facts.landingEnd = open.windowEnd
                facts.landingStatusAtSwitch = open.status(at: switchAt)
                if open.clockTimeZoneIdentifier == nil {
                    landing.refresh(at: open.windowEnd.addingTimeInterval(60), device: destination)
                    if let later = landing.doses.first(where: { $0.id == open.id }), later.clockTimeZoneIdentifier != nil {
                        facts.landingLaterClock = later.clockTimeZoneIdentifier
                        facts.landingLaterEnd = later.windowEnd
                    }
                }
                lines.append(words.landingLine(theDose: theDose, slotName: slotName, isWindow: departure.windowEndAt != nil, switchAt: switchAt, facts: facts))
            }
        }

        return TravelExample(heading: heading, lines: lines, facts: facts)
    }
}

/// A medication's doses on a trip, as plain values, refreshed by the app's own
/// `DoseReconciliation.refreshPlan` and changed the way `DoseRepository` changes rows.
struct TripSimulation {
    struct Dose {
        var id = UUID()
        var occurrenceKey: String
        var regimenVersion: Int
        var scheduledAt: Date
        var windowEndAt: Date?
        var graceWindowMinutes: Int
        var timingLabel: String
        var timingID: UUID?
        var clockTimeZoneIdentifier: String?
        var spacingHoldHours: Int?
        var completedAt: Date?
        var isTaken = false

        var windowEnd: Date {
            windowEndAt ?? scheduledAt.addingTimeInterval(TimeInterval(graceWindowMinutes * 60))
        }

        func status(at date: Date) -> DoseStatus {
            if completedAt != nil { return isTaken ? .takenOnTime : .skipped }
            if date < scheduledAt { return .upcoming }
            return date <= windowEnd ? .due : .overdue
        }

        mutating func copy(_ occurrence: GeneratedDoseOccurrence) {
            occurrenceKey = occurrence.occurrenceKey
            scheduledAt = occurrence.scheduledAt
            windowEndAt = occurrence.windowEndAt
            graceWindowMinutes = occurrence.graceWindowMinutes
            timingLabel = occurrence.timingLabel
            timingID = occurrence.timingID
            clockTimeZoneIdentifier = occurrence.clockTimeZoneIdentifier
            spacingHoldHours = occurrence.spacingHoldHours
        }
    }

    let regimen: MedicationRegimen
    let medicationID: UUID
    let preferences: AppPreferences
    private(set) var doses: [Dose] = []

    init(regimen: MedicationRegimen, medicationID: UUID, preferences: AppPreferences) {
        self.regimen = regimen
        self.medicationID = medicationID
        self.preferences = preferences
    }

    var idForKey: [String: UUID] {
        Dictionary(doses.map { ($0.occurrenceKey, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    /// The app's refresh at `date` with the device in `device` (a short horizon: the trip).
    mutating func refresh(at date: Date, device: TimeZone) {
        let rows = doses.map { dose in
            DoseReconciliation.Row(
                id: dose.id, occurrenceKey: dose.occurrenceKey, regimenVersion: dose.regimenVersion,
                scheduledAt: dose.scheduledAt, windowEnd: dose.windowEnd, timingLabel: dose.timingLabel,
                timingID: dose.timingID, isCompleted: dose.completedAt != nil, isUntouched: dose.completedAt == nil,
                clockTimeZoneIdentifier: dose.clockTimeZoneIdentifier, completedAt: dose.completedAt, isTaken: dose.isTaken
            )
        }
        let last = doses
            .filter { $0.isTaken && $0.completedAt != nil }
            .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
            .map { DoseRescheduling.LastTakenDose(completedAt: $0.completedAt ?? .distantPast, timingID: $0.timingID, timingLabel: $0.timingLabel) }
        let plan = DoseReconciliation.refreshPlan(
            existing: rows, regimen: regimen, medicationID: medicationID, lastTaken: last,
            engine: DoseScheduleEngine(deviceClock: .fixed(device)), preferences: preferences,
            referenceDate: date, horizonDays: 21
        )
        for (id, occurrence) in plan.updates {
            if let index = doses.firstIndex(where: { $0.id == id }) {
                doses[index].copy(occurrence)
                doses[index].regimenVersion = regimen.version
            }
        }
        for occurrence in plan.inserts {
            var dose = Dose(
                occurrenceKey: occurrence.occurrenceKey, regimenVersion: regimen.version,
                scheduledAt: occurrence.scheduledAt, graceWindowMinutes: occurrence.graceWindowMinutes,
                timingLabel: occurrence.timingLabel
            )
            dose.copy(occurrence)
            doses.append(dose)
        }
        let deleted = Set(plan.deletes)
        doses.removeAll { deleted.contains($0.id) }
    }

    mutating func take(key: String, at date: Date) {
        guard let index = doses.firstIndex(where: { $0.occurrenceKey == key }) else { return }
        doses[index].completedAt = date
        doses[index].isTaken = true
    }
}

/// The example's sentences. Every value in them is a fact from the simulation.
private struct Words {
    let home: TimeZone
    let destination: TimeZone
    let locale: Locale

    var homePlace: String { SlotClockLabel.placeName(of: home) }
    var destinationPlace: String { SlotClockLabel.placeName(of: destination) }

    func time(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone)
        style.timeZone = zone
        return date.formatted(style)
    }

    func zone(of identifier: String?) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? home
    }

    /// "today", "tomorrow" or the weekday, relative to `reference` on `zone`'s calendar.
    func dayWord(_ date: Date, relativeTo reference: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: reference), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return String(localized: "that day", comment: "Travel example: the landing day")
        case 1: return String(localized: "the next day", comment: "Travel example: the day after landing")
        default:
            var style = Date.FormatStyle(locale: locale, timeZone: zone).weekday(.wide)
            style.timeZone = zone
            return String(localized: "on \(date.formatted(style))", comment: "Travel example: a weekday, e.g. on Sunday")
        }
    }

    func hoursText(_ hours: Int) -> String {
        hours == 1
            ? String(localized: "1 hour", comment: "Travel example: one hour")
            : String(localized: "\(hours) hours", comment: "Travel example: a number of hours")
    }

    func heading(difference: Int) -> String {
        let hours = abs(difference) / 3600
        let minutes = (abs(difference) % 3600) / 60
        let amount = minutes == 0 ? hoursText(hours) : String(localized: "\(hours) h \(minutes) min", comment: "Travel example: a time difference with minutes")
        if difference == 0 {
            return String(localized: "If you fly from \(homePlace) to \(destinationPlace):", comment: "Travel example heading, same time")
        }
        return difference > 0
            ? String(localized: "If you fly from \(homePlace) to \(destinationPlace) (\(amount) ahead):", comment: "Travel example heading, destination ahead")
            : String(localized: "If you fly from \(homePlace) to \(destinationPlace) (\(amount) behind):", comment: "Travel example heading, destination behind")
    }

    func clockLine(doseName: String, occurrence: GeneratedDoseOccurrence, follows: Bool, mixed: Bool) -> String {
        let clock = zone(of: occurrence.clockTimeZoneIdentifier)
        let other = follows ? home : destination
        let line: String
        if let end = occurrence.windowEndAt {
            let here = "\(time(occurrence.scheduledAt, in: clock))–\(time(end, in: clock))"
            let there = "\(time(occurrence.scheduledAt, in: other))–\(time(end, in: other))"
            line = follows
                ? String(localized: "\(doseName): anytime \(here) \(destinationPlace) time (\(there) at home).", comment: "Travel example: a slot that follows you")
                : String(localized: "\(doseName): stays \(here) \(homePlace) time (\(there) in \(destinationPlace)).", comment: "Travel example: a slot kept on home time")
        } else {
            let at = time(occurrence.scheduledAt, in: clock)
            let there = time(occurrence.scheduledAt, in: other)
            line = follows
                ? String(localized: "\(doseName): \(at) \(destinationPlace) time (\(there) at home).", comment: "Travel example: a specific time that follows you")
                : String(localized: "\(doseName): stays at \(at) \(homePlace) time (\(there) in \(destinationPlace)); reminders come then.", comment: "Travel example: a specific time kept on home time")
        }
        guard mixed, follows else { return line }
        return line + " " + String(localized: "Specific times stay on \(homePlace) time.", comment: "Travel example: the Automatic setting's specific times")
    }

    func flightLine(
        slotName: String, takenAt: Date, flightHours: Int, landed: Date,
        next: TripSimulation.Dose, usualStart: Date?, facts: TravelExample.Facts, spacing: TravelSpacing, usualGap: Int
    ) -> String {
        let clock = zone(of: next.clockTimeZoneIdentifier)
        let place = next.clockTimeZoneIdentifier == nil ? homePlace : SlotClockLabel.placeName(of: clock)
        let opens = time(next.scheduledAt, in: clock)
        let gap = hoursText(facts.hoursAfterLast ?? 0)
        let day = dayWord(next.scheduledAt, relativeTo: landed, in: clock)
        let lead = String(
            localized: "Take it at \(time(takenAt, in: home)) at home, then fly \(hoursText(flightHours)): you land at \(time(landed, in: destination)) \(destinationPlace) time.",
            comment: "Travel example: the long-flight scenario"
        )
        let outcome: String
        if facts.offeredSameDay {
            outcome = String(localized: "You get another \(slotName) dose that day, from \(opens) \(place) time, \(gap) after the last.", comment: "Travel example: a second dose on the landing day")
        } else if facts.sameDayWindowOpenAtLanding {
            outcome = String(localized: "You won't get a second \(slotName) dose that calendar day; the next one opens \(day) at \(opens) \(place) time, \(gap) after the last.", comment: "Travel example: no second dose on the landing day")
        } else if facts.nextHeldHours != nil, let usualStart {
            outcome = String(localized: "The next \(slotName) dose opens \(day) at \(opens) \(place) time instead of \(time(usualStart, in: clock)): \(gap) after the last.", comment: "Travel example: the next dose held back by the minimum hours")
        } else if spacing == .calendarDay, let gapHours = facts.hoursAfterLast, gapHours < usualGap - 2 {
            outcome = String(localized: "The next \(slotName) dose opens \(day) at \(opens) \(place) time, only \(gap) after the last: that day was shorter.", comment: "Travel example: calendar-day spacing after an eastward flight")
        } else {
            outcome = String(localized: "The next \(slotName) dose opens \(day) at \(opens) \(place) time, \(gap) after the last.", comment: "Travel example: the next dose after landing")
        }
        return lead + " " + outcome
    }

    func landingLine(theDose: String, slotName: String, isWindow: Bool, switchAt: Date, facts: TravelExample.Facts) -> String {
        let lead = String(
            localized: "If your phone changes to \(destinationPlace) time while \(theDose) is open (\(time(switchAt, in: home)) at home), ",
            comment: "Travel example: the landing-during-a-dose scenario, start of the sentence"
        )
        guard let end = facts.landingEnd, let start = facts.landingStart else { return lead }
        let clock = zone(of: facts.landingClock)
        let rest: String
        if facts.landingClock == nil {
            var text = String(localized: "it keeps \(homePlace) time: take it by \(time(end, in: home)) \(homePlace) time (\(time(end, in: destination)) \(destinationPlace) time).", comment: "Travel example: an open dose finishing on the old clock")
            if let laterEnd = facts.landingLaterEnd {
                let later = isWindow ? slotName.lowercased(with: locale) : slotName
                text += " " + String(localized: "If you haven't by then, it moves on to \(destinationPlace)'s \(later), until \(time(laterEnd, in: zone(of: facts.landingLaterClock))) there.", comment: "Travel example: an untaken dose moving on west")
            }
            rest = text
        } else {
            switch facts.landingStatusAtSwitch {
            case .upcoming:
                rest = String(localized: "it switches to \(destinationPlace) time and opens at \(time(start, in: clock)) there.", comment: "Travel example: an open dose moved to a later local window")
            case .overdue:
                rest = String(localized: "it switches to \(destinationPlace) time, where that window ended at \(time(end, in: clock)): it shows as late.", comment: "Travel example: an open dose moved into a closed local window")
            default:
                rest = String(localized: "it switches to \(destinationPlace) time: take it by \(time(end, in: clock)) there.", comment: "Travel example: an open dose moved to an open local window")
            }
        }
        return lead + rest
    }
}
