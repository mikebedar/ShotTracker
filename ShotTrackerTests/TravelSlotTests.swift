import Foundation
import SwiftData
import Testing
@testable import ShotTracker

/// Decision 2026-10-23, "Morning (Paris)": named-slot doses follow the device's clock
/// when it travels, specific times keep their home instant, and a medication can choose
/// either ("When travelling"). Fixed zones throughout: home America/New_York, device
/// Europe/Paris. October 2026: Paris leaves summer time on Oct 25, New York on Nov 1, so
/// the clocks are six hours apart until the 25th and five that week.
@MainActor
struct TravelSlotTests {
    private typealias T = TestSupport
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let enUS = Locale(identifier: "en_US")
    private let morning = DailyTiming(kind: .morning)
    private let evening = DailyTiming(kind: .evening)

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        T.date(y, m, d, h, min)
    }

    private func normalized(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Morning (6–12) and evening (17–21), daily, home New York, since Oct 1.
    private func twiceDaily(_ context: ModelContext, timings: [DailyTiming]? = nil, travelPolicy: TravelTimePolicy? = nil) throws -> Medication {
        let medication = try T.medication(
            "Metformin",
            timings: timings ?? [morning, evening],
            anchor: utc(2026, 10, 1, 12),
            timeZone: newYork.identifier,
            context: context
        )
        medication.regimens.first?.travelPolicy = travelPolicy
        try context.save()
        return medication
    }

    /// The doses whose own clock puts them on `day` (y, m, d), per slot.
    private func doses(of medication: Medication, onLocalDay day: DateComponents) -> [ScheduledDose] {
        medication.scheduledDoses
            .filter {
                DoseReconciliation.day(of: $0.scheduledAt, clock: $0.clockTimeZoneIdentifier, home: calendar(newYork)) == day
            }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DateComponents {
        DateComponents(year: y, month: m, day: d)
    }

    // MARK: Generation follows the device

    @Test func newYorkToParisAndBack() throws {
        let context = try T.makeContext()
        let medication = try twiceDaily(context)

        // At home on Oct 22: New York mornings.
        try T.refresh(context, at: utc(2026, 10, 22, 12), device: newYork)
        let homeMorning = try #require(doses(of: medication, onLocalDay: day(2026, 10, 24)).first)
        #expect(homeMorning.scheduledAt == utc(2026, 10, 24, 10), "6:00 EDT")
        #expect(homeMorning.clockTimeZoneIdentifier == nil)
        #expect(!homeMorning.occurrenceKey.contains("@"))

        // Paris from Oct 23, 10:00 New York (16:00 Paris).
        try T.refresh(context, at: utc(2026, 10, 23, 14), device: paris)
        for date in 24...31 {
            let localDay = doses(of: medication, onLocalDay: day(2026, 10, date))
            #expect(localDay.map(\.timingLabel) == ["morning", "evening"], "Oct \(date): one morning, one evening")
            #expect(localDay.allSatisfy { $0.clockTimeZoneIdentifier == paris.identifier })
            #expect(localDay.allSatisfy { $0.occurrenceKey.hasSuffix("@Europe/Paris") })
        }
        let parisMorning = try #require(doses(of: medication, onLocalDay: day(2026, 10, 24)).first)
        #expect(parisMorning.id == homeMorning.id, "The same row moved: re-keyed, not duplicated")
        #expect(parisMorning.scheduledAt == utc(2026, 10, 24, 4), "6:00 CEST")
        // Paris leaves summer time on the 25th: still 6:00 on the Paris clock.
        #expect(doses(of: medication, onLocalDay: day(2026, 10, 26)).first?.scheduledAt == utc(2026, 10, 26, 5), "6:00 CET")

        // Today in Paris (Oct 23, 16:00): the New York morning (10:00–16:00 UTC) is still
        // open, and Paris's morning has closed — it stays on New York's clock rather than
        // vanish into the past. The evening moves to the Paris evening.
        let today = doses(of: medication, onLocalDay: day(2026, 10, 23))
        #expect(today.map(\.timingLabel) == ["morning", "evening"])
        #expect(today.first?.clockTimeZoneIdentifier == nil)
        #expect(today.last?.scheduledAt == utc(2026, 10, 23, 15), "17:00 CEST")

        // Back in New York on Oct 28.
        try T.refresh(context, at: utc(2026, 10, 28, 14), device: newYork)
        for date in 29...31 {
            let localDay = doses(of: medication, onLocalDay: day(2026, 10, date))
            #expect(localDay.map(\.timingLabel) == ["morning", "evening"])
            #expect(localDay.allSatisfy { $0.clockTimeZoneIdentifier == nil && !$0.occurrenceKey.contains("@") })
        }
        #expect(doses(of: medication, onLocalDay: day(2026, 10, 29)).first?.scheduledAt == utc(2026, 10, 29, 10), "6:00 EDT")
        #expect(doses(of: medication, onLocalDay: day(2026, 11, 2)).first?.scheduledAt == utc(2026, 11, 2, 11), "6:00 EST")
        let keys = medication.scheduledDoses.map(\.occurrenceKey)
        #expect(Set(keys).count == keys.count)
    }

    @Test func dstWeeksKeepTheLocalMorning() throws {
        let context = try T.makeContext()
        let medication = try T.medication(
            "Vitamin", timings: [morning], anchor: utc(2026, 3, 1, 12), timeZone: newYork.identifier, context: context
        )
        // In Paris across the EU change (Mar 29); New York changed on Mar 8.
        try T.refresh(context, at: utc(2026, 3, 20, 12), device: paris)
        let byDay = { (date: Int) in self.doses(of: medication, onLocalDay: self.day(2026, 3, date)).first }
        #expect(byDay(28)?.scheduledAt == utc(2026, 3, 28, 5), "6:00 CET")
        #expect(byDay(29)?.scheduledAt == utc(2026, 3, 29, 4), "6:00 CEST, the day the clocks change")
        #expect(byDay(30)?.scheduledAt == utc(2026, 3, 30, 4))

        // Five hours apart until the 29th, six after: what home says changes with it.
        let dayParts = AppPreferences.default.dayParts
        let before = try #require(byDay(28))
        let after = try #require(byDay(30))
        let beforeText = DoseClockText(dose: before, dayParts: dayParts, device: paris, locale: enUS)
        let afterText = DoseClockText(dose: after, dayParts: dayParts, device: paris, locale: enUS)
        #expect(normalized(beforeText.detail(before.scheduledAt)) == "Home: Night · 1:00 AM")
        #expect(normalized(afterText.detail(after.scheduledAt)) == "Home: Night · 12:00 AM")
        #expect(normalized(afterText.point(after.scheduledAt)) == "Morning (Paris) · 6:00 AM")
    }

    // MARK: A zone change mid-day

    @Test func aZoneChangeAfterTheMorningDoseDoesNotAskForASecondOne() throws {
        let context = try T.makeContext()
        let medication = try twiceDaily(context)
        try T.refresh(context, at: utc(2026, 10, 23, 10, 30), device: newYork)
        let nyMorning = try #require(doses(of: medication, onLocalDay: day(2026, 10, 23)).first)
        try DoseRepository.applyAction(.taken, to: nyMorning, now: utc(2026, 10, 23, 11), timeZone: newYork, context: context)

        // The phone lands in Paris at 19:00 local (13:00 New York).
        let landed = utc(2026, 10, 23, 17)
        try T.refresh(context, at: landed, device: paris)

        let today = doses(of: medication, onLocalDay: day(2026, 10, 23))
        #expect(today.count == 2, "No second Morning on the same local day")
        #expect(today.first?.id == nyMorning.id)
        #expect(today.first?.lastAction == .taken)
        let parisEvening = try #require(today.last)
        #expect(parisEvening.timingLabel == "evening")
        #expect(parisEvening.scheduledAt == utc(2026, 10, 23, 15), "The evening moved to the Paris evening, 17:00 CEST")
        #expect(parisEvening.clockTimeZoneIdentifier == paris.identifier)
        #expect(DoseStatusEvaluator().effectiveStatus(for: parisEvening, now: landed) == .due)

        // Today's list in Paris: the morning (done) and the evening, nothing else.
        let buckets = TodayBucketing.bucket(
            doses: medication.scheduledDoses,
            statusFor: { DoseStatusEvaluator().effectiveStatus(for: $0, now: landed) },
            now: landed,
            calendar: calendar(paris)
        )
        #expect(buckets.completed.map(\.id) == [nyMorning.id])
        #expect(buckets.takeNow.map(\.id) == [parisEvening.id])
        #expect(buckets.overdue.isEmpty && buckets.comingUpSoon.isEmpty && buckets.laterToday.isEmpty && buckets.tonight.isEmpty)
    }

    @Test func anOvernightFlightKeepsTheEveningDoseThatIsDue() throws {
        let context = try T.makeContext()
        let medication = try twiceDaily(context)
        try T.refresh(context, at: utc(2026, 10, 23, 10, 30), device: newYork)
        let nyMorning = try #require(doses(of: medication, onLocalDay: day(2026, 10, 23)).first)
        try DoseRepository.applyAction(.taken, to: nyMorning, now: utc(2026, 10, 23, 11), timeZone: newYork, context: context)

        // Over the Atlantic the phone switches to Paris at 1:30 AM Oct 24 (7:30 PM New
        // York): New York's evening (17–21) is due; Paris's Oct 23 evening has passed.
        let switched = utc(2026, 10, 23, 23, 30)
        try T.refresh(context, at: switched, device: paris)
        let evening = try #require(doses(of: medication, onLocalDay: day(2026, 10, 23)).last)
        #expect(evening.timingLabel == "evening")
        #expect(evening.clockTimeZoneIdentifier == nil, "Stays on New York's clock until its window closes")
        #expect(evening.scheduledAt == utc(2026, 10, 23, 21))
        #expect(DoseStatusEvaluator().effectiveStatus(for: evening, now: switched) == .due)
        #expect(!DoseSupersession.supersededIDs(for: medication, now: switched, calendar: calendar(paris)).contains(evening.id))
        #expect(doses(of: medication, onLocalDay: day(2026, 10, 23)).count == 2)

        // Paris's Oct 24 morning is next.
        let nextMorning = try #require(doses(of: medication, onLocalDay: day(2026, 10, 24)).first)
        #expect(nextMorning.scheduledAt == utc(2026, 10, 24, 4))

        // Taken on the plane, then a refresh at 8 AM Paris: one morning and one evening
        // for Oct 24, the 23rd's evening still the one taken.
        try DoseRepository.applyAction(.taken, to: evening, now: utc(2026, 10, 24, 0, 30), timeZone: paris, context: context)
        #expect(evening.status == .takenOnTime)
        let breakfast = utc(2026, 10, 24, 6)
        try T.refresh(context, at: breakfast, device: paris)
        #expect(doses(of: medication, onLocalDay: day(2026, 10, 23)).count == 2)
        #expect(doses(of: medication, onLocalDay: day(2026, 10, 24)).map(\.timingLabel) == ["morning", "evening"])
        var parisCalendar = calendar(paris)
        parisCalendar.locale = enUS
        let onParisDay = medication.scheduledDoses.filter { parisCalendar.isDate($0.scheduledAt, inSameDayAs: breakfast) }
        #expect(onParisDay.count == 2, "Today in Paris: the morning and the evening, nothing more")
    }

    @Test func flyingWestAMissedMorningComesBackWhenItIsStillMorningThere() throws {
        // Home Paris, morning not taken; at 1 PM Paris (7 AM New York) the phone is in New
        // York: that morning is still ahead there.
        let context = try T.makeContext()
        let medication = try T.medication("Vitamin", timings: [morning], anchor: utc(2026, 10, 1, 12), timeZone: paris.identifier, context: context)
        try T.refresh(context, at: utc(2026, 10, 23, 8), device: paris)
        let now = utc(2026, 10, 23, 11)
        try T.refresh(context, at: now, device: newYork)
        let today = try #require(doses(of: medication, onLocalDay: day(2026, 10, 23)).first)
        #expect(today.clockTimeZoneIdentifier == newYork.identifier)
        #expect(today.scheduledAt == utc(2026, 10, 23, 10), "6:00 in New York")
        #expect(DoseStatusEvaluator().effectiveStatus(for: today, now: now) == .due)
        #expect(doses(of: medication, onLocalDay: day(2026, 10, 23)).count == 1)
    }

    // MARK: Specific times and the override

    @Test func specificTimesKeepTheirHomeInstant() throws {
        let context = try T.makeContext()
        let eight = DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))
        let medication = try twiceDaily(context, timings: [eight])
        try T.refresh(context, at: utc(2026, 10, 22, 12), device: newYork)
        let keysAtHome = Set(medication.scheduledDoses.map(\.occurrenceKey))
        try T.refresh(context, at: utc(2026, 10, 23, 14), device: paris)
        let keysAway = Set(medication.scheduledDoses.map(\.occurrenceKey))
        #expect(keysAtHome.isSubset(of: keysAway), "Nothing re-keyed")
        #expect(!keysAway.contains { $0.contains("@") })
        let dose = try #require(medication.scheduledDoses.first { $0.scheduledAt == utc(2026, 10, 24, 12) })
        #expect(dose.clockTimeZoneIdentifier == nil)
        let text = DoseClockText(dose: dose, dayParts: .standard, device: paris, locale: enUS)
        #expect(text.slot == nil)
        #expect(normalized(text.point(dose.scheduledAt)) == "8:00 AM home · 2:00 PM here")
    }

    @Test func theOverrideWorksBothWays() throws {
        let context = try T.makeContext()
        // A named slot kept on home time.
        let kept = try twiceDaily(context, timings: [morning], travelPolicy: .staysOnHome)
        // A specific time that follows the device.
        let eight = DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))
        let follows = try twiceDaily(context, timings: [eight], travelPolicy: .followsMe)
        try T.refresh(context, at: utc(2026, 10, 23, 14), device: paris)

        let keptMorning = try #require(doses(of: kept, onLocalDay: day(2026, 10, 24)).first)
        #expect(keptMorning.scheduledAt == utc(2026, 10, 24, 10), "6:00 New York")
        #expect(keptMorning.clockTimeZoneIdentifier == nil)
        let keptText = DoseClockText(dose: keptMorning, dayParts: .standard, device: paris, locale: enUS)
        #expect(normalized(keptText.point(keptMorning.scheduledAt)) == "Morning (home) · 6:00 AM")
        #expect(normalized(keptText.detail(utc(2026, 10, 24, 12))) == "Here: Afternoon · 2:00 PM")

        let followsEight = try #require(doses(of: follows, onLocalDay: day(2026, 10, 24)).first)
        #expect(followsEight.scheduledAt == utc(2026, 10, 24, 6), "8:00 Paris")
        #expect(followsEight.clockTimeZoneIdentifier == paris.identifier)
        #expect(followsEight.slotTitle.replacingOccurrences(of: "\u{202F}", with: " ").hasPrefix("8:00"), "Its time on its own clock")
    }

    @Test func existingRegimensGetTheDefaultForTheirTimings() {
        // Main's stores have no travel field: nil = by timing kind.
        let regimen = MedicationRegimen(anchorDate: utc(2026, 10, 1, 12))
        #expect(regimen.travelPolicyRaw == nil)
        #expect(regimen.travelPolicy(for: DailyTiming(kind: .morning)) == .followsMe)
        #expect(regimen.travelPolicy(for: DailyTiming(kind: .bedtime)) == .followsMe)
        #expect(regimen.travelPolicy(for: DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))) == .staysOnHome)
        regimen.travelPolicy = .staysOnHome
        #expect(regimen.travelPolicy(for: DailyTiming(kind: .morning)) == .staysOnHome)
    }

    @Test func changingTheTravelSettingIsAScheduleChange() throws {
        let context = try T.makeContext()
        let medication = try twiceDaily(context, timings: [morning])
        var draft = MedicationDraft(medication: medication)
        #expect(draft.travelPolicy == nil)
        #expect(draft.defaultTravelPolicy == .followsMe)
        draft.travelPolicy = .followsMe
        #expect(!draft.scheduleDiffers(from: medication.regimens.active), "Picking the default changes nothing")
        draft.travelPolicy = .staysOnHome
        #expect(draft.scheduleDiffers(from: medication.regimens.active))

        // A mix of slots and specific times has no single default ("Automatic").
        draft.timings = [morning, DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))]
        #expect(draft.defaultTravelPolicy == nil)
    }

    // MARK: Labels

    @Test func labelsNameTheClock() {
        let parisMorningStart = utc(2026, 10, 24, 4)   // 6:00 Paris, 0:00 New York
        let parisMorningEnd = utc(2026, 10, 24, 10)
        let follows = SlotClockLabel(
            slotTitle: "Morning", windowStart: parisMorningStart, windowEnd: parisMorningEnd,
            clock: paris, home: newYork, device: paris, locale: enUS
        )
        #expect(follows.placement == .followsDevice("Paris"))
        #expect(follows.title == "Morning (Paris)")
        #expect(normalized(follows.detail(utc(2026, 10, 24, 6))) == "Home: Night · 2:00 AM")
        // The part of day is the window's (its middle, 3:00 AM at home), not the instant's.
        #expect(normalized(follows.detail(parisMorningEnd, by: true)) == "Home: Night · by 6:00 AM")
        #expect(follows.shortDetail == "Home: Night")
        #expect(follows.spokenTitle == "Morning in Paris")
        #expect(normalized(follows.spokenDetail(utc(2026, 10, 24, 6))) == "at home it's night, 2:00 AM")
        #expect(follows.titled("Morning dose") == "Morning dose (Paris)")

        let homeMorningStart = utc(2026, 10, 24, 10)   // 6:00 New York, 12:00 Paris
        let homeMorningEnd = utc(2026, 10, 24, 16)
        let kept = SlotClockLabel(
            slotTitle: "Morning", windowStart: homeMorningStart, windowEnd: homeMorningEnd,
            clock: newYork, home: newYork, device: paris, locale: enUS
        )
        #expect(kept.placement == .onHome)
        #expect(kept.title == "Morning (home)")
        #expect(normalized(kept.detail(utc(2026, 10, 24, 12))) == "Here: Afternoon · 2:00 PM")
        #expect(kept.spokenTitle == "Morning, home time")
        #expect(normalized(kept.spokenDetail(utc(2026, 10, 24, 12))) == "here it's afternoon, 2:00 PM")

        let atHome = SlotClockLabel(
            slotTitle: "Morning", windowStart: homeMorningStart, windowEnd: homeMorningEnd,
            clock: newYork, home: newYork, device: newYork, locale: enUS
        )
        #expect(atHome.placement == .oneClock)
        #expect(atHome.title == "Morning")
        #expect(atHome.detail(homeMorningStart) == nil)
        #expect(atHome.shortDetail == nil)

        // A Paris dose seen back home names its clock, and home.
        let history = SlotClockLabel(
            slotTitle: "Morning", windowStart: parisMorningStart, windowEnd: parisMorningEnd,
            clock: paris, home: newYork, device: newYork, locale: enUS
        )
        #expect(history.title == "Morning (Paris)")
        #expect(history.shortDetail == "Home: Night")
    }

    @Test func partsOfTheDayComeFromTheRoutineWindows() {
        let parts = AppPreferences.default.dayParts
        #expect(parts.name(forMinute: 2 * 60) == "Night")
        #expect(parts.name(forMinute: 7 * 60) == "Morning")
        #expect(parts.name(forMinute: 11 * 60 + 30) == "Noon")
        #expect(parts.name(forMinute: 15 * 60) == "Afternoon")
        #expect(parts.name(forMinute: 18 * 60) == "Evening")
        #expect(parts.name(forMinute: 20 * 60 + 30) == "Night")
        #expect(parts.name(forMinute: 23 * 60 + 30) == "Night")

        var early = AppPreferences.default
        early.defaultSlotWindows[TimingAnchorKind.morning.rawValue] = DoseWindow(start: ClockTime(hour: 4, minute: 30), end: ClockTime(hour: 9, minute: 0))
        #expect(early.dayParts.name(forMinute: 4 * 60 + 45) == "Morning", "An early riser's morning")
    }

    @Test func placesAreNamedByCity() {
        #expect(SlotClockLabel.placeName(of: TimeZone(identifier: "America/Argentina/Buenos_Aires")!) == "Buenos Aires")
        #expect(SlotClockLabel.placeName(of: paris) == "Paris")
        #expect(SlotClockLabel.placeName(of: TimeZone(identifier: "Etc/GMT-2")!, at: utc(2026, 10, 24, 0)) == "GMT+2")
    }

    // MARK: Notifications, widget, history

    @Test func remindersAreReplannedOnTheNewClock() throws {
        let context = try T.makeContext()
        let medication = try twiceDaily(context, timings: [morning])
        let evaluator = DoseStatusEvaluator()

        try T.refresh(context, at: utc(2026, 10, 22, 12), device: newYork)
        let homeDose = try #require(doses(of: medication, onLocalDay: day(2026, 10, 24)).first)
        let homeKey = homeDose.occurrenceKey
        let atHome = NotificationPlanner.doseReminders(
            for: medication.scheduledDoses, preferences: .default, evaluator: evaluator,
            now: utc(2026, 10, 22, 12), calendar: calendar(newYork), localTimeZone: newYork
        )
        let homeReminder = try #require(atHome.first { $0.identifier == homeKey + "-0" })
        #expect(homeReminder.fireDate == utc(2026, 10, 24, 15), "11:00 New York, an hour before the window closes")
        #expect(normalized(homeReminder.body) == "Morning dose · take by 12:00 PM.")

        try T.refresh(context, at: utc(2026, 10, 23, 14), device: paris)
        let away = NotificationPlanner.doseReminders(
            for: medication.scheduledDoses, preferences: .default, evaluator: evaluator,
            now: utc(2026, 10, 23, 14), calendar: calendar(paris), localTimeZone: paris
        )
        #expect(!away.contains { $0.occurrenceKey == homeKey }, "The New York plan is gone")
        let parisKey = homeDose.occurrenceKey  // the same row, re-keyed
        #expect(parisKey.hasSuffix("@Europe/Paris"))
        let parisReminder = try #require(away.first { $0.identifier == parisKey + "-0" })
        #expect(parisReminder.fireDate == utc(2026, 10, 24, 9), "11:00 Paris")
        #expect(normalized(parisReminder.body) == "Morning dose (Paris) · Home: Night · take by 12:00 PM.")
    }

    @Test func theWidgetFollowsTheDevice() throws {
        let context = try T.makeContext()
        let medication = try twiceDaily(context)
        try T.refresh(context, at: utc(2026, 10, 23, 14), device: paris)
        let dose = try #require(doses(of: medication, onLocalDay: day(2026, 10, 24)).first)
        let item = WidgetSnapshotWriter.makeItem(dose)
        #expect(item.clockTimeZoneIdentifier == paris.identifier)
        #expect(item.slotTitle == "Morning")
        #expect(normalized(item.timeText(localTimeZone: paris)) == "Morning (Paris) · by 12:00 PM · Home: Night")
        #expect(normalized(item.detailText(localTimeZone: paris)) == "Home: Night · by 6:00 AM")

        // Its timeline: on the Paris day, due from 6:00 Paris.
        let snapshot = TodayWidgetSnapshot(generatedAt: utc(2026, 10, 23, 14), showMedicationNames: true, items: [item], dayParts: AppPreferences.default.dayParts)
        #expect(item.resolvedStatus(now: utc(2026, 10, 24, 3, 59)) == .upcoming)
        #expect(item.resolvedStatus(now: utc(2026, 10, 24, 4)) == .due)
        #expect(item.resolvedStatus(now: utc(2026, 10, 24, 10, 1)) == .overdue)
        #expect(snapshot.items(relevantAt: utc(2026, 10, 23, 21), calendar: calendar(paris)).isEmpty, "Not before its Paris day")
        #expect(snapshot.items(relevantAt: utc(2026, 10, 24, 5), calendar: calendar(paris)).map(\.occurrenceKey) == [dose.occurrenceKey])

        // A snapshot written before the clock fields existed still decodes.
        let old = try JSONDecoder().decode(TodayWidgetSnapshot.self, from: JSONEncoder().encode(
            TodayWidgetSnapshot(generatedAt: .now, showMedicationNames: true, items: [])
        ))
        #expect(old.items.isEmpty)
    }

    @Test func aDoseTakenInTheParisMorningIsOnTimeAndRemembersItsClock() throws {
        let context = try T.makeContext()
        let medication = try twiceDaily(context, timings: [morning])
        try T.refresh(context, at: utc(2026, 10, 23, 14), device: paris)
        let dose = try #require(doses(of: medication, onLocalDay: day(2026, 10, 24)).first)

        // 8:05 in Paris: on time for the Paris morning (it is 2:05 AM in New York).
        try DoseRepository.applyAction(.taken, to: dose, now: utc(2026, 10, 24, 6, 5), timeZone: paris, context: context)
        #expect(dose.status == .takenOnTime)
        let event = try #require(medication.doseEvents.first)
        #expect(event.timeZoneIdentifier == paris.identifier)
        #expect(event.minutesLate == 0)

        // History: the local slot and the home time.
        let historyText = DoseClockText(dose: dose, medication: medication, dayParts: .standard, device: event.timeZone ?? paris, locale: enUS)
        #expect(historyText.awaySlot?.title == "Morning (Paris)")
        #expect(historyText.awaySlot?.shortDetail == "Home: Night")
        let logged = ZonedTimeFormatter(home: newYork, local: paris, locale: enUS, localName: "Paris")
        #expect(normalized(logged.dateTime(event.loggedAt)) == "Oct 24 at 2:05 AM home · 8:05 AM Paris")

        // The CSV says which clock, wherever it's exported.
        let csv = normalized(HistoryCSVExporter.csv(doseEvents: medication.doseEvents, refillEvents: [], timeZone: newYork)) ?? ""
        #expect(csv.contains("2026-10-24,8:05 AM,GMT+2"))
        #expect(csv.contains("Scheduled 2026-10-24 6:00 AM GMT+2 (Morning (Paris); Home: Night · 12:00 AM EDT)"))

        let stats = AdherenceStats.compute(
            doses: medication.scheduledDoses,
            statusFor: { DoseStatusEvaluator().effectiveStatus(for: $0, now: utc(2026, 10, 24, 12)) },
            now: utc(2026, 10, 24, 12)
        )
        #expect(stats.lateCount == 0)
    }
}
