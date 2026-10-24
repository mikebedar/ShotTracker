import Foundation
import SwiftData
import Testing
import UserNotifications
@testable import ShotTracker

/// Decision 2026-10-23: schedules keep their home (creation) time zone; wherever a dose
/// time is shown, a device in another zone sees both clocks — "8:00 AM home · 2:00 PM
/// here" — and the same zone reads exactly as before. Fixed zones throughout: home
/// America/New_York, device Europe/Paris, including the weeks around DST changes.
@MainActor
struct TimeZoneDisplayTests {
    private typealias T = TestSupport
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let enUS = Locale(identifier: "en_US")

    private func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        T.date(y, m, d, h, min)
    }

    private func formatter(home: TimeZone? = nil, local: TimeZone? = nil) -> ZonedTimeFormatter {
        ZonedTimeFormatter(home: home ?? newYork, local: local ?? paris, locale: enUS)
    }

    // MARK: Formatter

    @Test func differentZonesShowBothClocks() {
        let eightInNewYork = utc(2026, 7, 14, 12)  // 8:00 EDT = 14:00 CEST
        #expect(normalized(formatter().time(eightInNewYork)) == "8:00 AM home · 2:00 PM here")
        #expect(normalized(formatter().spokenTime(eightInNewYork)) == "8:00 AM home time, 2:00 PM local time")
        #expect(normalized(formatter().dateTime(eightInNewYork)) == "Jul 14 at 8:00 AM home · 2:00 PM here")
        #expect(normalized(formatter(home: newYork, local: newYork).dateTime(eightInNewYork)) == "Jul 14, 2026 at 8:00 AM", "Unchanged at home")
        #expect(normalized(formatter().timeWithZoneNames(eightInNewYork)) == "8:00 AM EDT (2:00 PM GMT+2 local)")
    }

    @Test func theSameClockReadsAsBefore() {
        let date = utc(2026, 7, 14, 12)
        let same = formatter(home: newYork, local: newYork)
        #expect(!same.differs(at: date))
        #expect(normalized(same.time(date)) == "8:00 AM")
        #expect(normalized(same.timeWithZoneNames(date)) == "8:00 AM")
        // A different identifier on the same offset isn't "elsewhere".
        let detroit = formatter(home: newYork, local: TimeZone(identifier: "America/Detroit")!)
        #expect(!detroit.differs(at: date))
        #expect(normalized(detroit.time(date)) == "8:00 AM")
        // No regimen to ask: one time, on the local clock.
        let unknown = ZonedTimeFormatter(home: nil, local: paris, locale: enUS)
        #expect(normalized(unknown.time(date)) == "2:00 PM")
    }

    @Test func dstWeeksUseEachZonesOwnOffset() {
        // US DST starts Mar 8 2026, the EU's Mar 29: three weeks five hours apart.
        #expect(normalized(formatter().time(utc(2026, 3, 7, 13))) == "8:00 AM home · 2:00 PM here")
        #expect(normalized(formatter().time(utc(2026, 3, 15, 12))) == "8:00 AM home · 1:00 PM here")
        #expect(normalized(formatter().time(utc(2026, 4, 1, 12))) == "8:00 AM home · 2:00 PM here")
        // The EU ends DST Oct 25, the US Nov 1: one week five hours apart again.
        #expect(normalized(formatter().time(utc(2026, 10, 28, 12))) == "8:00 AM home · 1:00 PM here")
        #expect(normalized(formatter().time(utc(2026, 11, 2, 13))) == "8:00 AM home · 2:00 PM here")
    }

    @Test func aHomeTimeOnAnotherDayNamesItsWeekday() {
        // Mon Jul 13, 11:00 PM in New York = Tue 5:00 AM in Paris.
        let late = utc(2026, 7, 14, 3)
        #expect(normalized(formatter().time(late)) == "11:00 PM Mon home · 5:00 AM here")
        #expect(normalized(formatter().dateTime(late)) == "Jul 13 at 11:00 PM home · Jul 14 at 5:00 AM here")
        #expect(normalized(formatter().spokenTime(late)) == "11:00 PM Monday home time, 5:00 AM local time")
    }

    @Test func zonesHaveReadableNames() {
        #expect(ZonedTimeFormatter.displayName(of: newYork, locale: enUS) == "New York (Eastern Time)")
        #expect(ZonedTimeFormatter.displayName(of: paris, locale: enUS) == "Paris (Central European Time)")
    }

    // MARK: Generation stays on the home clock

    @Test func dosesStayAtHomeTimesAcrossAHomeDSTChange() throws {
        let context = try T.makeContext()
        let medication = try T.medication(
            "Lisinopril",
            timings: [DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))],
            anchor: utc(2026, 3, 1, 12),
            timeZone: newYork.identifier,
            context: context
        )
        try T.refresh(context, at: utc(2026, 3, 7, 6))

        var newYorkCalendar = Calendar(identifier: .gregorian)
        newYorkCalendar.timeZone = newYork
        let around = medication.scheduledDoses
            .filter { $0.scheduledAt >= utc(2026, 3, 7, 0) && $0.scheduledAt < utc(2026, 3, 10, 0) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
        #expect(around.count == 3)
        #expect(around.allSatisfy { newYorkCalendar.component(.hour, from: $0.scheduledAt) == 8 })
        #expect(around.allSatisfy { $0.homeTimeZone == newYork })

        let texts = around.map { normalized(ZonedTimeFormatter(home: $0.homeTimeZone, local: paris, locale: enUS).time($0.scheduledAt)) }
        // New York springs forward at 2:00 on Mar 8, so that day's 8:00 is already EDT.
        #expect(texts == ["8:00 AM home · 2:00 PM here", "8:00 AM home · 1:00 PM here", "8:00 AM home · 1:00 PM here"])
    }

    @Test func aHomeEveningDoseAfterLocalMidnightIsNotSuperseded() {
        let medication = Medication(displayName: "Ozempic")
        // Evening 17:00–21:00 New York = 23:00–03:00 Paris: it starts on the local
        // "yesterday" and is still open after local midnight.
        func evening(_ day: Int) -> ScheduledDose {
            ScheduledDose(
                occurrenceKey: "e\(day)", regimenVersion: 1, scheduledAt: utc(2026, 7, day, 21),
                timingLabel: "evening", reminderWindowMinutes: 60, graceWindowMinutes: 180,
                windowEndAt: utc(2026, 7, day + 1, 1), medication: medication
            )
        }
        let doses = [evening(13), evening(14)]
        var parisCalendar = Calendar(identifier: .gregorian)
        parisCalendar.timeZone = paris
        let oneAMParis = utc(2026, 7, 13, 23)  // Jul 14, 01:00 Paris
        #expect(DoseSupersession.supersededIDs(in: doses, now: oneAMParis, calendar: parisCalendar).isEmpty)
        let fourAMParis = utc(2026, 7, 14, 2)  // its window closed at 03:00 Paris
        #expect(DoseSupersession.supersededIDs(in: doses, now: fourAMParis, calendar: parisCalendar) == [doses[0].id])
    }

    // MARK: Notifications and the widget

    @Test func reminderTextNamesBothClocks() throws {
        let medication = Medication(displayName: "Metformin")
        // Kept on home time: a slot that stays on New York's clock in Paris.
        let regimen = MedicationRegimen(anchorDate: utc(2026, 7, 1, 12), timeZoneIdentifier: newYork.identifier, travelPolicy: .staysOnHome, medication: medication)
        medication.regimens = [regimen]
        let morning = ScheduledDose(
            occurrenceKey: "m", regimenVersion: 1, scheduledAt: utc(2026, 7, 14, 10),
            timingLabel: "morning", reminderWindowMinutes: 60, graceWindowMinutes: 180,
            windowEndAt: utc(2026, 7, 14, 16), reminderAt: utc(2026, 7, 14, 15), medication: medication
        )
        let text = NotificationPlanner.content(for: morning, fireDate: utc(2026, 7, 14, 15), isFollowUp: false, localTimeZone: paris)
        let both = ZonedTimeFormatter(home: newYork, local: paris).time(utc(2026, 7, 14, 16))
        // 6:00–12:00 New York is 12:00–18:00 in Paris: the afternoon there.
        #expect(text.body == "Morning dose (home) · Here: Afternoon · take by \(both).")
        #expect(normalized(both).hasSuffix("home · 6:00 PM here"))

        let home = NotificationPlanner.content(for: morning, fireDate: utc(2026, 7, 14, 15), isFollowUp: false, localTimeZone: newYork)
        #expect(home.body == "Morning dose · take by \(ZonedTimeFormatter(home: newYork, local: newYork).time(utc(2026, 7, 14, 16))).", "At home the text is unchanged")
    }

    @Test func remindersArePinnedToTheirInstant() throws {
        let fire = Date.now.addingTimeInterval(3 * 24 * 3600).rounded(toMinutes: 1)
        let trigger = NotificationScheduler.trigger(for: fire, timeZone: newYork)
        #expect(trigger.dateComponents.timeZone == newYork)
        #expect(trigger.nextTriggerDate() == fire, "A trigger made in New York fires at that instant from anywhere")
    }

    @Test func theWidgetShowsBothClocks() {
        let item = WidgetDoseItem(
            occurrenceKey: "k", displayName: "Metformin", kindSymbol: "pills.fill", avatarHue: 0,
            takeWithFood: false, timingLabel: "morning", scheduledAt: utc(2026, 7, 14, 10),
            windowEnd: utc(2026, 7, 14, 16), isFlexibleWindow: true, snoozedUntil: nil,
            isTaken: false, isSkipped: false, storedStatus: "upcoming",
            homeTimeZoneIdentifier: newYork.identifier
        )
        // A slot on its home clock (an older snapshot, or one kept on home time).
        #expect(normalized(item.timeText(localTimeZone: paris)) == "Morning (home) · by 12:00 PM · Here: Afternoon")
        #expect(normalized(item.detailText(localTimeZone: paris) ?? "") == "Here: Afternoon · by 6:00 PM")
        #expect(normalized(item.timeText(localTimeZone: newYork)) == "by 12:00 PM")
        #expect(item.detailText(localTimeZone: newYork) == nil)

        // A specific time keeps both clocks.
        var exact = item
        exact.isFlexibleWindow = false
        #expect(normalized(exact.timeText(localTimeZone: paris)) == "6:00 AM home · 12:00 PM here")
    }

    @Test func theExportNamesBothZones() throws {
        let context = try T.makeContext()
        let medication = try T.medication(
            "Metformin",
            timings: [DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))],
            anchor: utc(2026, 7, 1, 12), timeZone: newYork.identifier, context: context
        )
        try T.refresh(context, at: utc(2026, 7, 14, 11))
        let dose = try #require(medication.scheduledDoses.first { $0.scheduledAt == utc(2026, 7, 14, 12) })
        try DoseRepository.applyAction(.taken, to: dose, now: utc(2026, 7, 14, 12, 5), timeZone: paris, context: context)

        let csv = normalized(HistoryCSVExporter.csv(doseEvents: medication.doseEvents, refillEvents: [], timeZone: paris))
        #expect(csv.contains("Scheduled 2026-07-14 8:00 AM EDT (2:00 PM GMT+2 local) (8:00 AM)"))
        #expect(csv.contains("2026-07-14,2:05 PM,GMT+2"), "Logged time on the clock it was logged on")
        // Exported later from New York, the row still reads on the Paris clock.
        let later = normalized(HistoryCSVExporter.csv(doseEvents: medication.doseEvents, refillEvents: [], timeZone: newYork))
        #expect(later.contains("2026-07-14,2:05 PM,GMT+2"))
    }

    // MARK: Changing the home zone

    @Test func changingTheHomeZoneCountsAsAScheduleChange() throws {
        let context = try T.makeContext()
        let medication = try T.medication(anchor: utc(2026, 7, 1, 12), timeZone: newYork.identifier, context: context)
        var draft = MedicationDraft(medication: medication)
        #expect(draft.homeTimeZoneIdentifier == newYork.identifier)
        #expect(!draft.scheduleDiffers(from: medication.regimens.active))
        draft.homeTimeZoneIdentifier = paris.identifier
        #expect(draft.scheduleDiffers(from: medication.regimens.active))
    }

    @Test func aNewHomeZoneReanchorsFutureDosesWithoutDuplicatingToday() throws {
        let context = try T.makeContext()
        let eight = DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))
        let medication = try T.medication("Lisinopril", timings: [eight], anchor: utc(2026, 7, 1, 12), timeZone: newYork.identifier, context: context)
        // In Paris on Jul 14: today's 8:00 New York dose (14:00 Paris) is taken.
        try T.refresh(context, at: utc(2026, 7, 14, 13))
        let today = try #require(medication.scheduledDoses.first { $0.scheduledAt == utc(2026, 7, 14, 12) })
        try DoseRepository.applyAction(.taken, to: today, now: utc(2026, 7, 14, 12, 10), context: context)

        // Re-home to Paris (EditMedicationView: a new version with the new zone).
        let now = utc(2026, 7, 14, 13)
        for regimen in medication.regimens { regimen.isActive = false }
        let rehomed = MedicationRegimen(
            version: 2, anchorDate: utc(2026, 7, 1, 12), timeZoneIdentifier: paris.identifier,
            timings: [eight], createdAt: now, medication: medication
        )
        medication.regimens.append(rehomed)
        context.insert(rehomed)
        try context.save()
        try T.refresh(context, at: now)

        var parisCalendar = Calendar(identifier: .gregorian)
        parisCalendar.timeZone = paris
        let julyFourteenth = medication.scheduledDoses.filter { parisCalendar.isDate($0.scheduledAt, inSameDayAs: utc(2026, 7, 14, 12)) }
        #expect(julyFourteenth.count == 1, "Today's taken dose absorbs the new 8:00 Paris slot")
        #expect(julyFourteenth.first?.lastAction == .taken)

        let tomorrow = medication.scheduledDoses.filter { parisCalendar.isDate($0.scheduledAt, inSameDayAs: utc(2026, 7, 15, 12)) }
        #expect(tomorrow.count == 1)
        #expect(tomorrow.first?.scheduledAt == utc(2026, 7, 15, 6), "8:00 in Paris")
        #expect(tomorrow.first?.regimenVersion == 2)
        #expect(tomorrow.first?.homeTimeZone == paris)
        let tomorrowTimes = ZonedTimeFormatter(home: tomorrow.first?.homeTimeZone, local: paris)
        #expect(!tomorrowTimes.differs(at: utc(2026, 7, 15, 6)))
        // The taken dose keeps the clock it was scheduled on.
        #expect(today.homeTimeZone == newYork)
    }
}

private extension Date {
    func rounded(toMinutes minutes: Int) -> Date {
        let step = TimeInterval(minutes * 60)
        return Date(timeIntervalSinceReferenceDate: (timeIntervalSinceReferenceDate / step).rounded(.down) * step)
    }
}
