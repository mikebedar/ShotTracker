import Foundation
import Testing
@testable import ShotTracker

@MainActor
struct SupplyForecastServiceTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Daily-morning med with `supply` units on hand.
    private func medication(supply: Int) -> Medication {
        let medication = Medication(
            displayName: "Daily Med",
            unitsPerContainer: 30,
            supplyContainers: [supply],
            supplyUnitLabel: "tablets"
        )
        let regimen = MedicationRegimen(
            anchorDate: Self.date(2026, 7, 1),
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            timings: [DailyTiming(kind: .morning)],
            createdAt: Self.date(2026, 7, 1),
            medication: medication
        )
        medication.regimens.append(regimen)
        return medication
    }

    @Test func dailyMedRunsOutAfterRemainingDoses() {
        let medication = medication(supply: 5)
        // Now = Jul 16 05:00, before the morning window opens → today's dose counts.
        // 5 doses: Jul 16, 17, 18, 19, 20 → runs out Jul 20.
        let projection = SupplyForecastService.projection(
            for: medication,
            engine: DoseScheduleEngine(),
            preferences: .default,
            now: Self.date(2026, 7, 16, 5),
            calendar: Self.calendar
        )
        #expect(projection != nil)
        #expect(Self.calendar.component(.day, from: projection!.runOutDate) == 20)
        #expect(projection!.daysRemaining == 4)
    }

    @Test func doseWhoseWindowClosedTodayDoesNotCount() {
        let medication = medication(supply: 1)
        // Now = Jul 16 13:00 — the 6–12 morning window already closed, so the one
        // remaining unit covers TOMORROW's dose.
        let projection = SupplyForecastService.projection(
            for: medication,
            engine: DoseScheduleEngine(),
            preferences: .default,
            now: Self.date(2026, 7, 16, 13),
            calendar: Self.calendar
        )
        #expect(projection != nil)
        #expect(Self.calendar.component(.day, from: projection!.runOutDate) == 17)
    }

    @Test func emptySupplyOrNoTrackingYieldsNil() {
        let empty = medication(supply: 0)
        #expect(SupplyForecastService.projection(
            for: empty, engine: DoseScheduleEngine(), preferences: .default,
            now: Self.date(2026, 7, 16), calendar: Self.calendar
        ) == nil)

        let untracked = Medication(displayName: "No Tracking")
        #expect(SupplyForecastService.projection(
            for: untracked, engine: DoseScheduleEngine(), preferences: .default,
            now: Self.date(2026, 7, 16), calendar: Self.calendar
        ) == nil)
    }
}
