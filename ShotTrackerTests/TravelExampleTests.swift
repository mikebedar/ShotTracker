import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// The live example under "When you travel" and "How this schedule works": both are
/// generated from the schedule (the example by the real engine and reconciliation on a
/// simulated trip), so these pin their facts and their words.
@MainActor
struct TravelExampleTests {
    private typealias T = TestSupport
    private let enUS = Locale(identifier: "en_US")
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        T.date(y, m, d, h, min)
    }

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func schedule(
        home: TimeZone,
        timings: [DailyTiming]? = nil,
        travel: TravelSettings = TravelSettings(),
        rule: RecurrenceRule? = nil,
        policy: MissedDosePolicy = .keepToSchedule
    ) -> TravelExample.Schedule {
        TravelExample.Schedule(
            timings: timings ?? [DailyTiming(kind: .morning)], rule: rule ?? RecurrenceRule(frequency: .daily),
            anchorDate: utc(2026, 10, 1, 12), graceWindowMinutes: 180, missedDosePolicy: policy, home: home, travel: travel
        )
    }

    /// The trip leaves on Oct 23 (the first dosing day after 4:00 UTC that day).
    private func example(_ schedule: TravelExample.Schedule, to destination: TimeZone) throws -> TravelExample {
        let example = try #require(TravelExample.make(schedule: schedule, destination: destination, preferences: .default, from: utc(2026, 10, 23, 4), locale: enUS))
        return TravelExample(heading: normalized(example.heading), lines: example.lines.map(normalized), facts: example.facts)
    }

    // MARK: The example

    @Test func newYorkToParisByCalendarDay() throws {
        let example = try example(schedule(home: newYork), to: paris)
        #expect(example.heading == "If you fly from New York to Paris (6 hours ahead):")
        #expect(example.lines.count == 3)
        #expect(example.lines[0] == "Morning dose: anytime 6:00 AM–12:00 PM Paris time (12:00 AM–6:00 AM at home).")
        #expect(example.lines[1] == "Take it at 8:00 AM at home, then fly 8 hours: you land at 11:00 PM Paris time. The next Morning dose opens the next day at 6:00 AM Paris time, only 16 hours after the last: that day was shorter.")
        #expect(example.lines[2] == "If your phone changes to Paris time while the morning dose is open (9:00 AM at home), it keeps New York time: take it by 12:00 PM New York time (6:00 PM Paris time).")
        #expect(example.facts.nextStart == utc(2026, 10, 24, 4))
        #expect(example.facts.nextClock == paris.identifier)
        #expect(example.facts.hoursAfterLast == 16 && example.facts.nextHeldHours == nil)
        #expect(example.facts.landingClock == nil && example.facts.landingStatusAtSwitch == .due)
    }

    @Test func theClockLineUsesTheDepartureDate() throws {
        // Leaving Oct 24, the day before Paris leaves summer time: the clock line reads
        // that day's six hours, like the heading; the next dose (Oct 25, CET) is five.
        let example = try #require(TravelExample.make(schedule: schedule(home: newYork, travel: TravelSettings(spacing: .minimumHours)), destination: paris, preferences: .default, from: utc(2026, 10, 24, 4), locale: enUS))
        #expect(normalized(example.heading) == "If you fly from New York to Paris (6 hours ahead):")
        #expect(normalized(example.lines[0]) == "Morning dose: anytime 6:00 AM–12:00 PM Paris time (12:00 AM–6:00 AM at home).")
        #expect(example.facts.nextStart == utc(2026, 10, 25, 8), "9:00 AM CET: 20 hours after 8:00 AM EDT")
        #expect(normalized(example.lines[1]).hasSuffix("opens the next day at 9:00 AM Paris time instead of 6:00 AM: 20 hours after the last."))
    }

    @Test func newYorkToParisKeepingTwentyHours() throws {
        let example = try example(schedule(home: newYork, travel: TravelSettings(spacing: .minimumHours, minimumHours: 20)), to: paris)
        #expect(example.lines[1].hasSuffix("The next Morning dose opens the next day at 10:00 AM Paris time instead of 6:00 AM: 20 hours after the last."))
        #expect(example.facts.nextStart == utc(2026, 10, 24, 8) && example.facts.nextHeldHours == 20)
    }

    @Test func newYorkToParisMovingTheOpenDoseNow() throws {
        let example = try example(schedule(home: newYork, travel: TravelSettings(landing: .moveNow)), to: paris)
        #expect(example.lines[2] == "If your phone changes to Paris time while the morning dose is open (9:00 AM at home), it switches to Paris time, where that window ended at 12:00 PM: it shows as late.")
        #expect(example.facts.landingClock == paris.identifier)
        #expect(example.facts.landingStatusAtSwitch == .overdue)
    }

    @Test func tokyoToNewYorkTheRepeatedDate() throws {
        let byDay = try example(schedule(home: tokyo), to: newYork)
        #expect(byDay.heading == "If you fly from Tokyo to New York (13 hours behind):")
        #expect(byDay.facts.sameDayWindowOpenAtLanding && !byDay.facts.offeredSameDay)
        #expect(byDay.lines[1].hasSuffix("You won't get a second Morning dose that calendar day; the next one opens the next day at 6:00 AM New York time, 35 hours after the last."))
        // Flying "back" in time, the open dose finishes in Tokyo, then moves on to New York's morning.
        #expect(byDay.lines[2].hasSuffix("it keeps Tokyo time: take it by 12:00 PM Tokyo time (11:00 PM New York time). If you haven't by then, it moves on to New York's morning, until 12:00 PM there."))
        #expect(byDay.facts.landingLaterClock == newYork.identifier)

        let twenty = try example(schedule(home: tokyo, travel: TravelSettings(spacing: .minimumHours, minimumHours: 20)), to: newYork)
        #expect(!twenty.facts.offeredSameDay, "16 hours after: still too soon")

        let ten = try example(schedule(home: tokyo, travel: TravelSettings(spacing: .minimumHours, minimumHours: 10)), to: newYork)
        #expect(ten.facts.offeredSameDay)
        #expect(ten.lines[1].hasSuffix("You get another Morning dose that day, from 6:00 AM New York time, 11 hours after the last."))
    }

    @Test func parisToNewYorkMovingNowMakesTheOpenDoseUpcoming() throws {
        let example = try example(schedule(home: paris, travel: TravelSettings(landing: .moveNow)), to: newYork)
        #expect(example.lines[2] == "If your phone changes to New York time while the morning dose is open (9:00 AM at home), it switches to New York time and opens at 6:00 AM there.")
        #expect(example.facts.landingStatusAtSwitch == .upcoming)
    }

    @Test func homeTimeSaysNothingMoves() throws {
        let example = try example(schedule(home: newYork, travel: TravelSettings(clock: .staysOnHome)), to: paris)
        #expect(example.lines == [
            "Morning dose: stays 6:00 AM–12:00 PM New York time (12:00 PM–6:00 PM in Paris).",
            "Because it stays on home time, long flights never bring two doses closer together, and a dose that's open when you land keeps its time.",
        ])
        #expect(!example.facts.follows)
    }

    @Test func specificTimesAndTheAutomaticMix() throws {
        let eight = DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))
        let follows = try example(schedule(home: newYork, timings: [eight], travel: TravelSettings(clock: .followsMe, spacing: .minimumHours)), to: paris)
        #expect(follows.lines[0] == "8:00 AM dose: 8:00 AM Paris time (2:00 AM at home).")
        #expect(follows.lines[2].contains("while the 8:00 AM dose is open (9:30 AM at home)"))

        let mixed = try example(schedule(home: newYork, timings: [DailyTiming(kind: .morning), DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 21, minute: 0))]), to: paris)
        #expect(mixed.lines[0].hasSuffix("Specific times stay on New York time."))
    }

    @Test func noTimeDifferenceNothingChanges() throws {
        let example = try example(schedule(home: newYork), to: TimeZone(identifier: "America/Detroit")!)
        #expect(example.lines == ["Both places keep the same time, so nothing about the morning dose changes."])
    }

    @Test func theExampleIsWhatTheStoreDoes() throws {
        // The same trip through the real repository: NY → Paris, hours mode.
        let context = try T.makeContext()
        let medication = try T.medication("Pill", anchor: utc(2026, 10, 1, 12), timeZone: newYork.identifier, context: context)
        let regimen = try #require(medication.regimens.first)
        regimen.travelSpacing = .minimumHours
        try T.refresh(context, at: utc(2026, 10, 23, 9), device: newYork)
        let dose = try #require(medication.scheduledDoses.first { $0.scheduledAt == utc(2026, 10, 23, 10) })
        try DoseRepository.applyAction(.taken, to: dose, now: utc(2026, 10, 23, 12), timeZone: newYork, context: context)
        let example = try example(schedule(home: newYork, travel: regimen.travelSettings), to: paris)
        let landed = try #require(example.facts.landedAt)
        try T.refresh(context, at: landed, device: paris)
        let next = medication.scheduledDoses.filter { $0.completedAt == nil && $0.windowEnd > landed }.min { $0.scheduledAt < $1.scheduledAt }
        #expect(next?.scheduledAt == example.facts.nextStart)
        #expect(next?.spacingHoldHours == example.facts.nextHeldHours)
    }

    @Test func destinationsDefaultFarFromHome() {
        let at = utc(2026, 10, 23, 12)
        #expect(TravelDestinations.defaultDestination(from: newYork, at: at).identifier == "Europe/Paris")
        #expect(TravelDestinations.defaultDestination(from: paris, at: at).identifier == "Asia/Tokyo")
        #expect(TravelDestinations.defaultDestination(from: tokyo, at: at).identifier == "America/New_York")
        #expect(TravelDestinations.defaultDestination(from: TimeZone(identifier: "Europe/London")!, at: at).identifier == "Asia/Tokyo")
        #expect(TravelDestinations.zones.count == TravelDestinations.identifiers.count, "Every listed zone exists")
    }

    @Test func flightHoursFollowTheDistanceInTime() {
        let at = utc(2026, 10, 23, 12)
        #expect(TravelExample.flightHours(from: newYork, to: paris, at: at) == 8)
        #expect(TravelExample.flightHours(from: newYork, to: tokyo, at: at) == 15)
        #expect(TravelExample.flightHours(from: newYork, to: TimeZone(identifier: "America/Chicago")!, at: at) == 3)
    }

    // MARK: How this schedule works

    private func inputs(
        timings: [DailyTiming]? = nil,
        rule: RecurrenceRule? = nil,
        policy: MissedDosePolicy = .keepToSchedule,
        travel: TravelSettings = TravelSettings(),
        allowSnooze: Bool = true,
        remindersEnabled: Bool = true
    ) -> ScheduleSummary.Inputs {
        ScheduleSummary.Inputs(
            timings: timings ?? [DailyTiming(kind: .morning), DailyTiming(kind: .bedtime)],
            rule: rule ?? RecurrenceRule(frequency: .daily),
            graceWindowMinutes: 180, missedDosePolicy: policy, minimumIntervalHours: 72,
            home: newYork, travel: travel, remindersEnabled: remindersEnabled, allowSnooze: allowSnooze
        )
    }

    private func summary(_ inputs: ScheduleSummary.Inputs) -> [ScheduleSummary.Line.Topic: String] {
        Dictionary(uniqueKeysWithValues: ScheduleSummary(inputs, preferences: .default, locale: enUS).lines.map { ($0.topic, normalized($0.text)) })
    }

    @Test func theDefaultSummary() {
        let lines = summary(inputs())
        #expect(lines[.timing] == "Every day: Morning anytime 6:00 AM–12:00 PM and Before bed anytime 8:00 PM–11:30 PM. Taking a dose early or anywhere in its window counts as on time.")
        #expect(lines[.missed] == "After its window closes a dose shows as overdue and can still be logged late until a later dose replaces it; the next dose stays on its usual day.")
        #expect(lines[.reminders] == "A reminder comes 1 hour before a window closes (at the time itself for a specific time), then again after 30 min, 2 hours, 12 hours, and 1 day until you log it. Snooze moves only this dose's reminder and deadline, 20 min each time; on time is still judged by the usual window.")
        #expect(lines[.travel] == "Morning and Before bed follow the local clock wherever you are, with home time shown too. One of each per calendar day where you are, so after a long flight east two doses can be closer than usual. A dose open when the time zone changes finishes on the old clock.")
    }

    @Test func theSummaryFollowsEveryChoice() {
        let hoursAndMove = summary(inputs(timings: [DailyTiming(kind: .morning)], travel: TravelSettings(spacing: .minimumHours, minimumHours: 18, landing: .moveNow)))
        #expect(hoursAndMove[.travel] == "Morning follows the local clock wherever you are, with home time shown too. After a time zone change the next one waits until at least 18 hours after the last, whatever the date. A dose open when the time zone changes moves to the local clock at once.")

        let home = summary(inputs(travel: TravelSettings(clock: .staysOnHome)))
        #expect(home[.travel] == "Doses stay on New York time wherever you are: reminders come at that moment and both clocks are shown. Long flights never move a dose.")

        let mixed = summary(inputs(timings: [DailyTiming(kind: .morning), DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 21, minute: 0))]))
        #expect(mixed[.travel]?.hasPrefix("Morning follows the local clock; specific times stay on New York time.") == true)
        #expect(mixed[.timing] == "Every day: Morning anytime 6:00 AM–12:00 PM and 9:00 PM, on time for 3 hours after. Taking a dose early or anywhere in its window counts as on time.")

        let weekly = summary(inputs(timings: [DailyTiming(kind: .evening)], rule: RecurrenceRule(frequency: .weekly, weekdays: [6]), policy: .rescheduleFromLastDose))
        #expect(weekly[.timing]?.hasPrefix("Every week on Friday: Evening anytime 5:00 PM–9:00 PM.") == true)
        #expect(weekly[.missed] == "Each dose sets the next one: it comes a week after you actually take it. You'll get a heads-up if you log one sooner than 3 days after the last.")

        let quiet = summary(inputs(allowSnooze: false, remindersEnabled: false))
        #expect(quiet[.reminders] == "No reminders. Snooze is off for this medication.")

        let skip = summary(inputs(policy: .skipIfLate))
        #expect(skip[.missed] == "Once a window closes, that dose counts as missed; wait for the next scheduled one rather than making it up.")
    }

    @Test func theSummaryOfASavedRegimenReadsItsValues() throws {
        let context = try T.makeContext()
        let medication = try T.medication("Shot", kind: .injection, timings: [DailyTiming(kind: .evening)], anchor: utc(2026, 10, 1, 12), timeZone: newYork.identifier, context: context)
        let regimen = try #require(medication.regimens.first)
        regimen.travelPolicy = .staysOnHome
        regimen.travelSpacing = .minimumHours
        let policy = ReminderPolicy(allowSnooze: false)
        policy.regimen = regimen
        regimen.reminderPolicies.append(policy)
        context.insert(policy)
        let lines = ScheduleSummary(ScheduleSummary.Inputs(regimen: regimen), preferences: .default, locale: enUS).lines
        #expect(lines.map(\.title) == ["When", "If you're late", "Reminders and snooze", "When you travel"])
        #expect(lines.last?.text.hasPrefix("Doses stay on New York time") == true)
        #expect(lines[2].text.hasSuffix("Snooze is off for this medication."))
    }
}
