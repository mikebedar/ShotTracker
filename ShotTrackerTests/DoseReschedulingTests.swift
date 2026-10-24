import Foundation
import Testing
@testable import ShotTracker

@MainActor
struct DoseReschedulingTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Builds a medication + a single active weekly regimen anchored on a Tuesday,
    /// with an optional taken dose to drive rolling.
    private static func weeklyMedication(
        policy: MissedDosePolicy,
        anchor: Date,
        takenAt: Date? = nil,
        minimumIntervalHours: Int? = nil
    ) -> Medication {
        let medication = Medication(displayName: "Weekly Shot", kind: .injection)
        let regimen = MedicationRegimen(
            anchorDate: anchor,
            timeZoneIdentifier: "UTC",
            recurrenceRule: RecurrenceRule(frequency: .weekly, weekdays: [3]), // Tuesday
            timings: [DailyTiming(kind: .exactTime, exactTime: ClockTime(hour: 8, minute: 0))],
            createdAt: anchor,
            missedDosePolicy: policy,
            minimumIntervalHours: minimumIntervalHours,
            medication: medication
        )
        medication.regimens = [regimen]

        if let takenAt {
            let dose = ScheduledDose(
                occurrenceKey: UUID().uuidString,
                regimenVersion: 1,
                scheduledAt: takenAt,
                timingLabel: "8:00-am",
                reminderWindowMinutes: 60,
                graceWindowMinutes: 180,
                status: .takenLate,
                lastAction: .taken,
                medication: medication
            )
            dose.completedAt = takenAt
            medication.scheduledDoses = [dose]
        }
        return medication
    }

    // MARK: engineInputs

    @Test func fixedPolicyUsesRegimenAnchorAndNoRolling() {
        let anchor = Self.date(2026, 7, 7) // Tuesday
        let med = Self.weeklyMedication(policy: .keepToSchedule, anchor: anchor, takenAt: Self.date(2026, 7, 8))
        let inputs = DoseRescheduling.engineInputs(for: med, regimen: med.regimens.first!)

        #expect(inputs.anchor == anchor)
        #expect(inputs.rollingInterval == nil)
        // Fixed policy still floors generation at the regimen version's creation day
        // (createdAt == anchor here), so nothing before the version existed can be
        // fabricated — but it doesn't block anything from the anchor forward. The floor is
        // a day, read on each occurrence's own clock (home, or local for a slot that
        // follows the device), not an instant.
        #expect(inputs.notBefore == nil)
        #expect(inputs.floorDay == anchor)
    }

    @Test func rollingWithNoHistoryFallsBackToRegimenAnchor() {
        let anchor = Self.date(2026, 7, 7)
        let med = Self.weeklyMedication(policy: .rescheduleFromLastDose, anchor: anchor, takenAt: nil)
        let inputs = DoseRescheduling.engineInputs(for: med, regimen: med.regimens.first!)

        #expect(inputs.anchor == anchor)
        #expect(inputs.rollingInterval == nil)
    }

    @Test func rollingWithHistoryAnchorsToLastDose() {
        let anchor = Self.date(2026, 7, 7)          // Tuesday
        let taken = Self.date(2026, 7, 8, 15)       // Wednesday 3pm, a day late
        let med = Self.weeklyMedication(policy: .rescheduleFromLastDose, anchor: anchor, takenAt: taken)
        let inputs = DoseRescheduling.engineInputs(for: med, regimen: med.regimens.first!)

        #expect(inputs.anchor == Self.calendar.startOfDay(for: taken))
        #expect(inputs.notBefore == taken)
        #expect(inputs.rollingInterval == DateComponents(day: 7))
    }

    // MARK: rolling generation via the engine

    @Test func weeklyTakenLateProjectsNextFromActualDate() {
        let engine = DoseScheduleEngine(deviceClock: .atHome)
        let anchor = Self.date(2026, 7, 7)          // Tuesday
        let taken = Self.date(2026, 7, 8, 15)       // Wednesday, a day late
        let med = Self.weeklyMedication(policy: .rescheduleFromLastDose, anchor: anchor, takenAt: taken)
        let regimen = med.regimens.first!
        let inputs = DoseRescheduling.engineInputs(for: med, regimen: regimen)

        let occurrences = engine.generateOccurrences(
            for: regimen,
            medicationID: med.id,
            from: taken,
            through: Self.date(2026, 8, 1),
            preferences: .default,
            anchorOverride: inputs.anchor,
            rollingInterval: inputs.rollingInterval,
            notBefore: inputs.notBefore
        )

        // Next dose should be Wednesday Jul 15 (7 days after the actual Wednesday take),
        // NOT Tuesday Jul 14 (the original weekday grid).
        let first = occurrences.first
        #expect(first != nil)
        let comps = Self.calendar.dateComponents([.year, .month, .day], from: first!.scheduledAt)
        #expect(comps.month == 7)
        #expect(comps.day == 15)

        // And nothing is generated on the just-taken day (notBefore excludes it).
        #expect(!occurrences.contains { Self.calendar.isDate($0.scheduledAt, inSameDayAs: taken) })
    }

    @Test func fixedWeeklyStaysOnOriginalWeekday() {
        let engine = DoseScheduleEngine(deviceClock: .atHome)
        let anchor = Self.date(2026, 7, 7) // Tuesday
        let taken = Self.date(2026, 7, 8)  // taken Wednesday
        let med = Self.weeklyMedication(policy: .keepToSchedule, anchor: anchor, takenAt: taken)
        let regimen = med.regimens.first!
        let inputs = DoseRescheduling.engineInputs(for: med, regimen: regimen)

        let occurrences = engine.generateOccurrences(
            for: regimen,
            medicationID: med.id,
            from: Self.date(2026, 7, 9),
            through: Self.date(2026, 7, 31),
            preferences: .default,
            anchorOverride: inputs.anchor,
            rollingInterval: inputs.rollingInterval,
            notBefore: inputs.notBefore
        )

        // Fixed: every occurrence stays on Tuesday (weekday 3) regardless of the late take.
        for occurrence in occurrences {
            #expect(Self.calendar.component(.weekday, from: occurrence.scheduledAt) == 3)
        }
    }

    // MARK: minimum-interval warning

    @Test func warnsWhenTakingSoonerThanMinimum() {
        let anchor = Self.date(2026, 7, 7)
        let taken = Self.date(2026, 7, 13, 8)      // took it Monday
        let med = Self.weeklyMedication(policy: .rescheduleFromLastDose, anchor: anchor, takenAt: taken, minimumIntervalHours: 72)

        // Trying to take again only 2 days later (< 3-day minimum).
        let warning = DoseRescheduling.minimumIntervalWarning(for: med, regimen: med.regimens.first!, takingAt: Self.date(2026, 7, 15, 8))
        #expect(warning != nil)
        #expect(warning?.minimumHours == 72)
    }

    @Test func noWarningWhenPastMinimum() {
        let anchor = Self.date(2026, 7, 7)
        let taken = Self.date(2026, 7, 13, 8)
        let med = Self.weeklyMedication(policy: .rescheduleFromLastDose, anchor: anchor, takenAt: taken, minimumIntervalHours: 72)

        // A full week later — well past the minimum.
        let warning = DoseRescheduling.minimumIntervalWarning(for: med, regimen: med.regimens.first!, takingAt: Self.date(2026, 7, 20, 8))
        #expect(warning == nil)
    }

    @Test func noWarningForFixedPolicy() {
        let anchor = Self.date(2026, 7, 7)
        let taken = Self.date(2026, 7, 13, 8)
        let med = Self.weeklyMedication(policy: .keepToSchedule, anchor: anchor, takenAt: taken)

        let warning = DoseRescheduling.minimumIntervalWarning(for: med, regimen: med.regimens.first!, takingAt: Self.date(2026, 7, 14, 8))
        #expect(warning == nil)
    }

    @Test func defaultPolicyMatchesKind() {
        #expect(MissedDosePolicy.defaultFor(kind: .injection) == .rescheduleFromLastDose)
        #expect(MissedDosePolicy.defaultFor(kind: .oral) == .keepToSchedule)
    }
}
