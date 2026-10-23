import Foundation
import Testing
@testable import ShotTracker

@MainActor
struct DoseWindowEngineTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 0))!
    }

    private func regimen(timing: DailyTiming) -> MedicationRegimen {
        MedicationRegimen(
            anchorDate: Self.date(2026, 7, 1),
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .daily),
            timings: [timing]
        )
    }

    @Test func namedSlotProducesWindowOccurrence() {
        let engine = DoseScheduleEngine()
        let regimen = regimen(timing: DailyTiming(kind: .morning))

        let occurrences = engine.generateOccurrences(
            for: regimen,
            medicationID: UUID(),
            from: Self.date(2026, 7, 14),
            through: Self.date(2026, 7, 14),
            preferences: .default
        )

        #expect(occurrences.count == 1)
        let occ = occurrences[0]
        // Default morning window is 6:00–12:00, lead 60 → reminder at 11:00.
        #expect(Self.calendar.component(.hour, from: occ.scheduledAt) == 6)         // window start
        #expect(occ.windowEndAt != nil)
        #expect(Self.calendar.component(.hour, from: occ.windowEndAt!) == 12)        // window end
        #expect(Self.calendar.component(.hour, from: occ.reminderAt) == 11)          // near close
    }

    @Test func exactTimeProducesPointOccurrence() {
        let engine = DoseScheduleEngine()
        let regimen = regimen(timing: DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 30)))

        let occurrences = engine.generateOccurrences(
            for: regimen,
            medicationID: UUID(),
            from: Self.date(2026, 7, 14),
            through: Self.date(2026, 7, 14),
            preferences: .default
        )

        #expect(occurrences.count == 1)
        let occ = occurrences[0]
        #expect(occ.windowEndAt == nil)   // a point, not a window
        #expect(Self.calendar.component(.hour, from: occ.scheduledAt) == 8)
        #expect(Self.calendar.component(.minute, from: occ.scheduledAt) == 30)
        #expect(occ.reminderAt == occ.scheduledAt) // remind at the exact time
    }

    @Test func perMedicationCustomWindowOverridesGlobal() {
        let engine = DoseScheduleEngine()
        let custom = DoseWindow(start: ClockTime(hour: 6, minute: 0), end: ClockTime(hour: 9, minute: 0))
        let regimen = regimen(timing: DailyTiming(kind: .morning, customWindow: custom))

        let occurrences = engine.generateOccurrences(
            for: regimen,
            medicationID: UUID(),
            from: Self.date(2026, 7, 14),
            through: Self.date(2026, 7, 14),
            preferences: .default
        )

        #expect(occurrences.count == 1)
        // Custom 6–9 window overrides the global morning 6–noon.
        #expect(Self.calendar.component(.hour, from: occurrences[0].windowEndAt!) == 9)
    }
}
