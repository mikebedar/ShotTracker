import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// The "When you travel" choices (2026-10-23, branch `travel-options`): the clock (follows
/// me / home time), long trips & date lines (calendar day / at least N hours) and landing
/// during a dose (finish on the old clock / move now), in every combination that matters,
/// over real refreshes. Fixed zones; October 2026: Paris leaves summer time Oct 25, New
/// York and Los Angeles Nov 1, Sydney is on summer time (UTC+11), Tokyo UTC+9.
@MainActor
struct TravelOptionsTests {
    private typealias T = TestSupport
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let sydney = TimeZone(identifier: "Australia/Sydney")!
    private let enUS = Locale(identifier: "en_US")

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        T.date(y, m, d, h, min)
    }

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// A daily medication (morning 6–12 by default) at home in `home`, since Oct 1, with
    /// the given travel choices.
    private func medication(
        _ context: ModelContext,
        home: TimeZone,
        timings: [DailyTiming]? = nil,
        spacing: TravelSpacing? = nil,
        hours: Int? = nil,
        landing: TravelLanding? = nil,
        clock: TravelTimePolicy? = nil
    ) throws -> Medication {
        let medication = try T.medication("Pill", timings: timings ?? [DailyTiming(kind: .morning)], anchor: utc(2026, 10, 1, 12), timeZone: home.identifier, context: context)
        let regimen = try #require(medication.regimens.first)
        regimen.travelSpacingRaw = spacing?.rawValue
        regimen.travelMinimumHours = hours
        regimen.travelLandingRaw = landing?.rawValue
        regimen.travelPolicy = clock
        try context.save()
        return medication
    }

    /// The doses whose own clock puts them on `day` (y, m, d).
    private func doses(of medication: Medication, onLocalDay y: Int, _ m: Int, _ d: Int) -> [ScheduledDose] {
        let home = calendar(medication.homeTimeZone() ?? .gmt)
        return medication.scheduledDoses
            .filter { DoseReconciliation.day(of: $0.scheduledAt, clock: $0.clockTimeZoneIdentifier, home: home) == DateComponents(year: y, month: m, day: d) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    private func take(_ dose: ScheduledDose, at date: Date, in zone: TimeZone, _ context: ModelContext) throws {
        try DoseRepository.applyAction(.taken, to: dose, now: date, timeZone: zone, context: context)
    }

    private func status(_ dose: ScheduledDose, at date: Date) -> DoseStatus {
        DoseStatusEvaluator().effectiveStatus(for: dose, now: date)
    }

    // MARK: Defaults and storage

    @Test func oldRegimensKeepTheBehaviourTheyHad() {
        let regimen = MedicationRegimen(anchorDate: utc(2026, 10, 1, 12))
        #expect(regimen.travelSpacingRaw == nil && regimen.travelMinimumHours == nil && regimen.travelLandingRaw == nil)
        #expect(regimen.travelSpacing == .calendarDay)
        #expect(regimen.travelLanding == .finishOnOldClock)
        #expect(regimen.effectiveTravelMinimumHours == 20)
        let rules = DoseReconciliation.TravelRules(regimen: regimen)
        #expect(rules.minimumHours == nil)
        #expect(rules.landing == .finishOnOldClock)
    }

    @Test func defaultHoursComeFromTheSchedule() {
        #expect(TravelSettings.defaultMinimumHours(for: RecurrenceRule(frequency: .daily)) == 20)
        #expect(TravelSettings.defaultMinimumHours(for: RecurrenceRule(frequency: .intervalDays, intervalDays: 3)) == 68)
        #expect(TravelSettings.defaultMinimumHours(for: RecurrenceRule(frequency: .weekly, weekdays: [2])) == 164)
        #expect(TravelSettings.defaultMinimumHours(for: RecurrenceRule(frequency: .weekly, weekdays: [2, 5])) == 68, "Mon and Thu: three days apart at the closest")
    }

    @Test func newMedicationsStartFromTheirKindAndTiming() {
        let morning = [DailyTiming(kind: .morning)]
        let eight = [DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))]
        let daily = RecurrenceRule(frequency: .daily)

        let pill = TravelSettings.suggested(kind: .oral, timeSensitive: nil, timings: morning, rule: daily)
        #expect(pill.clock == nil && pill.clock(for: morning[0]) == .followsMe)
        #expect(pill.spacing == .calendarDay && pill.landing == .finishOnOldClock)

        let shot = TravelSettings.suggested(kind: .injection, timeSensitive: nil, timings: morning, rule: daily)
        #expect(shot.clock == .staysOnHome && shot.spacing == .minimumHours && shot.minimumHours == 20)

        let exact = TravelSettings.suggested(kind: .oral, timeSensitive: nil, timings: eight, rule: daily)
        #expect(exact.clock(for: eight[0]) == .staysOnHome && exact.spacing == .minimumHours)

        let critical = TravelSettings.suggested(kind: .oral, timeSensitive: true, timings: morning, rule: daily)
        #expect(critical.clock == .staysOnHome && critical.spacing == .minimumHours)
    }

    @Test func eachChoiceIsAScheduleChangeOnlyWhenItChangesSomething() throws {
        let context = try T.makeContext()
        let medication = try medication(context, home: newYork)
        var draft = MedicationDraft(medication: medication)
        #expect(draft.travelSpacing == .calendarDay && draft.travelLanding == .finishOnOldClock && draft.travelMinimumHours == 20)
        #expect(!draft.scheduleDiffers(from: medication.regimens.active))

        draft.travelMinimumHours = 16
        #expect(!draft.scheduleDiffers(from: medication.regimens.active), "N only counts in hours mode")
        draft.travelSpacing = .minimumHours
        #expect(draft.scheduleDiffers(from: medication.regimens.active))
        draft.travelSpacing = .calendarDay
        draft.travelLanding = .moveNow
        #expect(draft.scheduleDiffers(from: medication.regimens.active))

        // A saved hours mode reads back, and its N too.
        let regimen = try #require(medication.regimens.active)
        regimen.travelSpacing = .minimumHours
        regimen.travelMinimumHours = 16
        let reread = MedicationDraft(medication: medication)
        #expect(reread.travelSpacing == .minimumHours && reread.travelMinimumHours == 16)
        #expect(!reread.scheduleDiffers(from: regimen))
    }

    // MARK: New York → Paris (east, six hours)

    @Test func newYorkToParisByCalendarDayAndByHours() throws {
        for spacing in [TravelSpacing.calendarDay, .minimumHours] {
            let context = try T.makeContext()
            let medication = try medication(context, home: newYork, spacing: spacing)
            try T.refresh(context, at: utc(2026, 10, 23, 10, 30), device: newYork)
            let nyMorning = try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first)
            try take(nyMorning, at: utc(2026, 10, 23, 12), in: newYork, context)   // 8:00 AM New York

            // Landed: 7:00 PM in Paris.
            try T.refresh(context, at: utc(2026, 10, 23, 17), device: paris)
            #expect(doses(of: medication, onLocalDay: 2026, 10, 23).count == 1, "\(spacing): no second Morning on Oct 23")
            let next = try #require(doses(of: medication, onLocalDay: 2026, 10, 24).first)
            #expect(next.clockTimeZoneIdentifier == paris.identifier)
            #expect(next.occurrenceKey.hasSuffix("@Europe/Paris"))
            if spacing == .calendarDay {
                #expect(next.scheduledAt == utc(2026, 10, 24, 4), "6:00 AM Paris, 16 hours after the last")
                #expect(next.spacingHoldHours == nil)
            } else {
                #expect(next.scheduledAt == utc(2026, 10, 24, 8), "10:00 AM Paris: 20 hours after 8:00 AM New York")
                #expect(next.spacingHoldHours == 20)
                #expect(next.windowEnd == utc(2026, 10, 24, 10), "Still closes at noon Paris")
                #expect(next.reminderAt == utc(2026, 10, 24, 9), "The usual reminder, an hour before it closes")
                #expect(status(next, at: utc(2026, 10, 24, 7)) == .upcoming)
                #expect(status(next, at: utc(2026, 10, 24, 8)) == .due)
            }
            // The day after is the usual Paris morning either way (CET from the 25th).
            #expect(doses(of: medication, onLocalDay: 2026, 10, 25).first?.scheduledAt == utc(2026, 10, 25, 5))
            #expect(doses(of: medication, onLocalDay: 2026, 10, 25).first?.spacingHoldHours == nil)
        }
    }

    @Test func undoingTheLastDoseLetsTheHeldDoseGoBack() throws {
        let context = try T.makeContext()
        let medication = try medication(context, home: newYork, spacing: .minimumHours)
        try T.refresh(context, at: utc(2026, 10, 23, 10, 30), device: newYork)
        let nyMorning = try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first)
        try take(nyMorning, at: utc(2026, 10, 23, 12), in: newYork, context)
        try T.refresh(context, at: utc(2026, 10, 23, 17), device: paris)
        let held = try #require(doses(of: medication, onLocalDay: 2026, 10, 24).first)
        let key = held.occurrenceKey
        #expect(held.spacingHoldHours == 20)

        try DoseRepository.applyAction(.pending, to: nyMorning, now: utc(2026, 10, 23, 17, 5), timeZone: paris, context: context)
        try T.refresh(context, at: utc(2026, 10, 23, 17, 5), device: paris)
        let back = try #require(doses(of: medication, onLocalDay: 2026, 10, 24).first)
        #expect(back.id == held.id && back.occurrenceKey == key, "Same row, same key")
        #expect(back.scheduledAt == utc(2026, 10, 24, 4) && back.spacingHoldHours == nil)
    }

    @Test func onceADoseIsTakenOnTheNewClockTheCalendarCountsAgain() throws {
        let context = try T.makeContext()
        let medication = try medication(context, home: newYork, spacing: .minimumHours)
        try T.refresh(context, at: utc(2026, 10, 23, 10, 30), device: newYork)
        try take(try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first), at: utc(2026, 10, 23, 12), in: newYork, context)
        try T.refresh(context, at: utc(2026, 10, 23, 17), device: paris)
        let held = try #require(doses(of: medication, onLocalDay: 2026, 10, 24).first)
        try take(held, at: utc(2026, 10, 24, 9, 55), in: paris, context)    // 11:55 AM Paris
        try T.refresh(context, at: utc(2026, 10, 24, 10), device: paris)
        let next = try #require(doses(of: medication, onLocalDay: 2026, 10, 25).first)
        #expect(next.scheduledAt == utc(2026, 10, 25, 5), "6:00 AM: only 19 hours later, but on the same clock")
        #expect(next.spacingHoldHours == nil)
    }

    @Test func atHomeTheHoursModeChangesNothing() throws {
        let context = try T.makeContext()
        let medication = try medication(context, home: newYork, spacing: .minimumHours, hours: 23)
        try T.refresh(context, at: utc(2026, 10, 23, 10, 30), device: newYork)
        try take(try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first), at: utc(2026, 10, 23, 15, 59), in: newYork, context)
        try T.refresh(context, at: utc(2026, 10, 23, 16), device: newYork)
        let next = try #require(doses(of: medication, onLocalDay: 2026, 10, 24).first)
        #expect(next.scheduledAt == utc(2026, 10, 24, 10), "6:00 AM, 14 hours after a late dose: one clock, no hold")
        #expect(next.spacingHoldHours == nil)
    }

    @Test func theDSTGapWeekShiftsTheHeldStart() throws {
        // Oct 26–31: New York on EDT, Paris already on CET — five hours apart.
        let context = try T.makeContext()
        let medication = try medication(context, home: newYork, spacing: .minimumHours)
        try T.refresh(context, at: utc(2026, 10, 27, 10, 30), device: newYork)
        try take(try #require(doses(of: medication, onLocalDay: 2026, 10, 27).first), at: utc(2026, 10, 27, 12), in: newYork, context)
        try T.refresh(context, at: utc(2026, 10, 27, 20), device: paris)
        let next = try #require(doses(of: medication, onLocalDay: 2026, 10, 28).first)
        #expect(next.scheduledAt == utc(2026, 10, 28, 8), "9:00 AM CET, 20 hours after 8:00 AM EDT (usual start 6:00 = 05:00 UTC)")
        #expect(next.windowEnd == utc(2026, 10, 28, 11))

        // Calendar day in the same week: the usual 6:00 AM CET.
        let other = try T.makeContext()
        let byDay = try self.medication(other, home: newYork)
        try T.refresh(other, at: utc(2026, 10, 27, 10, 30), device: newYork)
        try take(try #require(doses(of: byDay, onLocalDay: 2026, 10, 27).first), at: utc(2026, 10, 27, 12), in: newYork, other)
        try T.refresh(other, at: utc(2026, 10, 27, 20), device: paris)
        #expect(doses(of: byDay, onLocalDay: 2026, 10, 28).first?.scheduledAt == utc(2026, 10, 28, 5))
    }

    // MARK: Tokyo → New York (east over the date line: a date lived twice)

    @Test func tokyoToNewYorkTheRepeatedDateByCalendarAndByHours() throws {
        // Morning taken at 8:00 AM Tokyo on Oct 23 (23:00 UTC Oct 22); landing in New York
        // at 11:00 AM on Oct 23, 16 hours later, the New York morning still open.
        let taken = utc(2026, 10, 22, 23)
        let landed = utc(2026, 10, 23, 15)
        for (spacing, hours, offeredAgain) in [(TravelSpacing.calendarDay, 20, false), (.minimumHours, 20, false), (.minimumHours, 10, true)] {
            let context = try T.makeContext()
            let medication = try medication(context, home: tokyo, spacing: spacing, hours: hours)
            try T.refresh(context, at: utc(2026, 10, 22, 22), device: tokyo)
            let tokyoMorning = try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first)
            try take(tokyoMorning, at: taken, in: tokyo, context)
            try T.refresh(context, at: landed, device: newYork)

            let newYorkOct23 = medication.scheduledDoses.filter {
                $0.clockTimeZoneIdentifier == newYork.identifier && calendar(newYork).isDate($0.scheduledAt, inSameDayAs: landed)
            }
            #expect((newYorkOct23.count == 1) == offeredAgain, "\(spacing) \(hours) h")
            if offeredAgain, let again = newYorkOct23.first {
                #expect(again.scheduledAt == utc(2026, 10, 23, 10), "The usual 6:00 AM: already 11 hours after the Tokyo dose")
                #expect(again.spacingHoldHours == nil)
                #expect(status(again, at: landed) == .due)
            }
            // Oct 24 in New York: the usual morning in every mode (35 hours after).
            let oct24 = medication.scheduledDoses.filter {
                $0.clockTimeZoneIdentifier == newYork.identifier && calendar(newYork).isDate($0.scheduledAt, inSameDayAs: utc(2026, 10, 24, 12))
            }
            #expect(oct24.map(\.scheduledAt) == [utc(2026, 10, 24, 10)], "\(spacing) \(hours) h")
        }
    }

    // MARK: Los Angeles → Sydney (west over the date line: a date skipped)

    /// Morning taken at 8:00 AM Los Angeles on Oct 22 (15:00 UTC); the phone switches to
    /// Sydney at take-off, 10:00 PM Los Angeles (4:00 PM Oct 23 in Sydney, 05:00 UTC Oct 23).
    private func losAngelesToSydney(spacing: TravelSpacing, landing: TravelLanding) throws -> (Medication, ModelContext) {
        let context = try T.makeContext()
        let medication = try medication(context, home: losAngeles, spacing: spacing, landing: landing)
        try T.refresh(context, at: utc(2026, 10, 22, 14), device: losAngeles)
        try take(try #require(doses(of: medication, onLocalDay: 2026, 10, 22).first), at: utc(2026, 10, 22, 15), in: losAngeles, context)
        try T.refresh(context, at: utc(2026, 10, 23, 5), device: sydney)
        return (medication, context)
    }

    @Test func westOverTheDateLineByCalendarDayFinishingOnTheOldClock() throws {
        let (medication, _) = try losAngelesToSydney(spacing: .calendarDay, landing: .finishOnOldClock)
        // Sydney's Oct 23 morning was over before take-off; Los Angeles's Oct 23 morning
        // (6–12 LA = 1–7 AM Sydney Oct 24) stays on its clock; then Sydney's Oct 24 from 6 AM.
        let oct23 = doses(of: medication, onLocalDay: 2026, 10, 23)
        #expect(oct23.count == 1)
        #expect(oct23.first?.clockTimeZoneIdentifier == nil, "Held on Los Angeles's clock")
        #expect(oct23.first?.scheduledAt == utc(2026, 10, 23, 13))
        #expect(doses(of: medication, onLocalDay: 2026, 10, 24).first?.scheduledAt == utc(2026, 10, 23, 19), "6:00 AM Sydney")
    }

    @Test func westOverTheDateLineByHoursTheNextDoseWaitsForTheOneTaken() throws {
        let (medication, context) = try losAngelesToSydney(spacing: .minimumHours, landing: .finishOnOldClock)
        // Sydney's Oct 23 is covered (it ended 10 hours after the last dose). Los Angeles's
        // Oct 23 morning, 22 hours after, stays open on its clock.
        let held = try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first)
        #expect(held.clockTimeZoneIdentifier == nil && held.scheduledAt == utc(2026, 10, 23, 13))
        let sydney24 = try #require(doses(of: medication, onLocalDay: 2026, 10, 24).first)
        #expect(sydney24.scheduledAt == utc(2026, 10, 23, 19))

        // Taken on the plane at 5:00 AM Sydney: Sydney's Oct 24 morning, an hour later,
        // is now covered and goes; Oct 25 is the next.
        try take(held, at: utc(2026, 10, 23, 18), in: sydney, context)
        try T.refresh(context, at: utc(2026, 10, 23, 18, 5), device: sydney)
        #expect(doses(of: medication, onLocalDay: 2026, 10, 24).isEmpty, "No second dose an hour later")
        let next = try #require(doses(of: medication, onLocalDay: 2026, 10, 25).first)
        #expect(next.scheduledAt == utc(2026, 10, 24, 19), "6:00 AM Sydney Oct 25, 25 hours after")
        #expect(next.spacingHoldHours == nil)
    }

    @Test func westOverTheDateLineByHoursMovingNowOffersOneDose() throws {
        let (medication, _) = try losAngelesToSydney(spacing: .minimumHours, landing: .moveNow)
        // Move now: the Los Angeles row is covered on the new clock, so it goes; no missed
        // dose for the skipped date, one dose at 6:00 AM Sydney on the 24th.
        #expect(doses(of: medication, onLocalDay: 2026, 10, 23).isEmpty)
        let open = medication.scheduledDoses.filter { $0.completedAt == nil && $0.windowEnd > utc(2026, 10, 23, 5) && $0.scheduledAt < utc(2026, 10, 24, 12) }
        #expect(open.map(\.scheduledAt) == [utc(2026, 10, 23, 19)])
        #expect(open.first?.clockTimeZoneIdentifier == sydney.identifier)
    }

    @Test func westOverTheDateLineByCalendarMovingNowRecordsTheSkippedDate() throws {
        let (medication, _) = try losAngelesToSydney(spacing: .calendarDay, landing: .moveNow)
        // Calendar day + move now: Oct 23's dose moves to Sydney's Oct 23 morning, which
        // ended before take-off: overdue there (a miss), then Oct 24 as usual.
        let oct23 = try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first)
        #expect(oct23.clockTimeZoneIdentifier == sydney.identifier)
        #expect(status(oct23, at: utc(2026, 10, 23, 5)) == .overdue)
        #expect(doses(of: medication, onLocalDay: 2026, 10, 24).first?.scheduledAt == utc(2026, 10, 23, 19))
    }

    // MARK: Landing during a dose

    @Test func landingMidWindowEastFinishOrMove() throws {
        // New York morning open (9:00 AM New York = 3:00 PM Paris) when the phone switches.
        for landing in TravelLanding.allCases {
            let context = try T.makeContext()
            let medication = try medication(context, home: newYork, landing: landing)
            try T.refresh(context, at: utc(2026, 10, 23, 12), device: newYork)
            let open = try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first)
            let switched = utc(2026, 10, 23, 13)
            try T.refresh(context, at: switched, device: paris)
            #expect(doses(of: medication, onLocalDay: 2026, 10, 23).map(\.id) == [open.id], "\(landing): still one dose for the day")
            let text = DoseClockText(dose: open, dayParts: .standard, device: paris, locale: enUS)
            switch landing {
            case .finishOnOldClock:
                #expect(open.clockTimeZoneIdentifier == nil)
                #expect(status(open, at: switched) == .due)
                #expect(text.awaySlot?.title == "Morning (home)")
            case .moveNow:
                #expect(open.clockTimeZoneIdentifier == paris.identifier)
                #expect(open.scheduledAt == utc(2026, 10, 23, 4), "Paris's morning, already over")
                #expect(status(open, at: switched) == .overdue, "Late, still takeable")
                #expect(text.awaySlot?.title == "Morning (Paris)", "Reads (Paris) at once")
                #expect(!DoseSupersession.supersededIDs(for: medication, now: switched, calendar: calendar(paris)).contains(open.id), "Same Paris day: not hidden")
            }
        }
    }

    @Test func landingMidWindowWestMoveMakesItUpcoming() throws {
        // Home Paris; morning open at 9:00 AM Paris (07:00 UTC) when the phone switches to
        // New York (3:00 AM there).
        for landing in TravelLanding.allCases {
            let context = try T.makeContext()
            let medication = try medication(context, home: paris, landing: landing)
            try T.refresh(context, at: utc(2026, 10, 23, 6), device: paris)
            let open = try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first)
            let switched = utc(2026, 10, 23, 7)
            try T.refresh(context, at: switched, device: newYork)
            switch landing {
            case .finishOnOldClock:
                #expect(open.clockTimeZoneIdentifier == nil && status(open, at: switched) == .due)
                // Once Paris's window closes, the untaken dose moves on to New York's morning.
                try T.refresh(context, at: utc(2026, 10, 23, 10, 5), device: newYork)
                #expect(open.clockTimeZoneIdentifier == newYork.identifier)
                #expect(status(open, at: utc(2026, 10, 23, 10, 5)) == .due)
            case .moveNow:
                #expect(open.clockTimeZoneIdentifier == newYork.identifier)
                #expect(open.scheduledAt == utc(2026, 10, 23, 10))
                #expect(status(open, at: switched) == .upcoming, "Opens at 6:00 AM New York")
            }
            #expect(doses(of: medication, onLocalDay: 2026, 10, 23).count == 1)
        }
    }

    @Test func overnightFlightMovingNowTheEveningIsMissed() throws {
        let context = try T.makeContext()
        let medication = try medication(context, home: newYork, timings: [DailyTiming(kind: .morning), DailyTiming(kind: .evening)], landing: .moveNow)
        try T.refresh(context, at: utc(2026, 10, 23, 20), device: newYork)
        let evening = try #require(doses(of: medication, onLocalDay: 2026, 10, 23).last)
        // 1:30 AM in Paris: the New York evening is open, Paris's evening long over.
        let switched = utc(2026, 10, 23, 23, 30)
        try T.refresh(context, at: switched, device: paris)
        #expect(evening.clockTimeZoneIdentifier == paris.identifier)
        #expect(evening.scheduledAt == utc(2026, 10, 23, 15))
        #expect(status(evening, at: switched) == .overdue)
        #expect(DoseSupersession.supersededIDs(for: medication, now: switched, calendar: calendar(paris)).contains(evening.id),
                "Yesterday's in Paris: today's doses replace it")
        let text = DoseClockText(dose: evening, dayParts: .standard, device: paris, locale: enUS)
        #expect(text.awaySlot?.title == "Evening (Paris)")
    }

    // MARK: Home time

    @Test func homeTimeIgnoresTheOtherChoices() throws {
        for (spacing, landing) in [(TravelSpacing.calendarDay, TravelLanding.finishOnOldClock), (.minimumHours, .moveNow)] {
            let context = try T.makeContext()
            let medication = try medication(context, home: newYork, spacing: spacing, landing: landing, clock: .staysOnHome)
            try T.refresh(context, at: utc(2026, 10, 23, 12), device: newYork)
            try take(try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first), at: utc(2026, 10, 23, 12), in: newYork, context)
            try T.refresh(context, at: utc(2026, 10, 23, 17), device: paris)
            #expect(medication.scheduledDoses.allSatisfy { $0.clockTimeZoneIdentifier == nil && $0.spacingHoldHours == nil })
            #expect(doses(of: medication, onLocalDay: 2026, 10, 24).first?.scheduledAt == utc(2026, 10, 24, 10), "6:00 AM New York, 24 hours later")
        }
    }

    // MARK: Labels, reminders, widget for a held dose

    @Test func aHeldDoseRemindsNoEarlierThanItOpensAndTheWidgetAgrees() throws {
        let context = try T.makeContext()
        let medication = try medication(context, home: newYork, spacing: .minimumHours, hours: 21)
        var preferences = AppPreferences.default
        preferences.windowReminderLeadMinutes = 180   // usually reminds at 9:00 AM
        try T.refresh(context, at: utc(2026, 10, 23, 10, 30), preferences: preferences, device: newYork)
        try take(try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first), at: utc(2026, 10, 23, 12), in: newYork, context)
        try T.refresh(context, at: utc(2026, 10, 23, 17), preferences: preferences, device: paris)
        let held = try #require(doses(of: medication, onLocalDay: 2026, 10, 24).first)
        #expect(held.scheduledAt == utc(2026, 10, 24, 9) && held.spacingHoldHours == 21, "11:00 AM Paris")
        #expect(held.reminderAt == utc(2026, 10, 24, 9), "Not at 9:00 AM, before it opens")

        let reminders = NotificationPlanner.doseReminders(
            for: medication.scheduledDoses, preferences: preferences, evaluator: DoseStatusEvaluator(),
            now: utc(2026, 10, 23, 17), calendar: calendar(paris), localTimeZone: paris
        )
        #expect(reminders.first { $0.occurrenceKey == held.occurrenceKey }?.fireDate == utc(2026, 10, 24, 9))

        let item = WidgetSnapshotWriter.makeItem(held)
        #expect(item.resolvedStatus(now: utc(2026, 10, 24, 8, 59)) == .upcoming)
        #expect(item.resolvedStatus(now: utc(2026, 10, 24, 9)) == .due)
    }

    @Test func aMinimumLongerThanTheWindowAllowsCoversThatDay() throws {
        // 23 hours after 8:00 AM New York is 1:00 PM Paris: Paris's Oct 24 morning (6–12)
        // can't keep it, so Oct 24 has no Morning dose and Oct 25's is the next.
        let context = try T.makeContext()
        let medication = try medication(context, home: newYork, spacing: .minimumHours, hours: 23)
        try T.refresh(context, at: utc(2026, 10, 23, 10, 30), device: newYork)
        try take(try #require(doses(of: medication, onLocalDay: 2026, 10, 23).first), at: utc(2026, 10, 23, 12), in: newYork, context)
        try T.refresh(context, at: utc(2026, 10, 23, 17), device: paris)
        #expect(doses(of: medication, onLocalDay: 2026, 10, 24).isEmpty)
        #expect(doses(of: medication, onLocalDay: 2026, 10, 25).first?.scheduledAt == utc(2026, 10, 25, 5))
    }
}
