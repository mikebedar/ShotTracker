import Foundation

/// Pure diff between a medication's persisted `ScheduledDose` rows and the engine's fresh
/// occurrences, used by `DoseRepository.refreshSchedules`. Split out (plain values in,
/// a plan out) so the rules are unit-testable without SwiftData.
///
/// Matching, in order:
/// 1. **By `occurrenceKey`** — the normal, idempotent case.
/// 2. **By slot identity on the same day** — the same `DailyTiming` (`timingID`), else the
///    same slot label, else the same instant. A key can change without the slot changing:
///    the routine window moved (the key embeds the start time), the device changed time
///    zone, the exact-time label format changed, or the regimen got a new version. An
///    untouched or snoozed row is re-keyed onto the new occurrence (it keeps its state);
///    a completed row keeps its key and the new occurrence is dropped — that slot was
///    already handled, and a second "due" copy of a dose already taken is the bug this
///    prevents.
/// 3. **Per-day capacity** — a completed row the new grid has no slot for (the timing was
///    edited from morning to noon after the morning dose was taken) still uses up one of
///    that day's new occurrences, earliest first: a once-a-day med edited after today's
///    dose doesn't ask for a second one today.
///
/// **Travel.** A slot that follows the device moves to the local clock when the device's
/// zone changes (its key gains `@zone`, so step 1 misses), and step 2 finds the row of the
/// same slot on the same **local day** — each side's date read on its own clock, so New
/// York's Oct 23 morning and Paris's Oct 23 morning are one dose. A taken or skipped row
/// absorbs the new occurrence (no second "Morning" that day). An open row moves to the
/// new clock only if its window there hasn't closed yet: a zone change never moves a
/// takeable dose into the past (an evening dose due over the Atlantic stays on New York's
/// clock until its window closes) and a missed dose stays as it was recorded — unless its
/// slot is still ahead on the new clock (flying west: the morning missed in Paris is
/// still to come in New York, the same local day).
///
/// Pruning: an unmatched, untouched row inside the generated range is deleted when it
/// belongs to the current regimen version (an old rolling grid, a phantom) or its window
/// hasn't closed yet (a slot the edit removed). Closed windows of older versions and
/// anything outside the range are kept: they are the record of missed doses that
/// `AdherenceStats` counts (the old rule deleted every untouched row once it left the
/// 7-day lookback, so 30-day adherence only ever saw a week of misses).
enum DoseReconciliation {
    struct Row: Hashable {
        let id: UUID
        let occurrenceKey: String
        let regimenVersion: Int
        let scheduledAt: Date
        let windowEnd: Date
        let timingLabel: String
        let timingID: UUID?
        let isCompleted: Bool
        let isUntouched: Bool
        /// The zone the row's times are on when it isn't the home zone (nil = home).
        let clockTimeZoneIdentifier: String?

        init(id: UUID, occurrenceKey: String, regimenVersion: Int, scheduledAt: Date, windowEnd: Date,
             timingLabel: String, timingID: UUID?, isCompleted: Bool, isUntouched: Bool,
             clockTimeZoneIdentifier: String? = nil) {
            self.id = id
            self.occurrenceKey = occurrenceKey
            self.regimenVersion = regimenVersion
            self.scheduledAt = scheduledAt
            self.windowEnd = windowEnd
            self.timingLabel = timingLabel
            self.timingID = timingID
            self.isCompleted = isCompleted
            self.isUntouched = isUntouched
            self.clockTimeZoneIdentifier = clockTimeZoneIdentifier
        }

        @MainActor
        init(_ dose: ScheduledDose) {
            self.init(
                id: dose.id,
                occurrenceKey: dose.occurrenceKey,
                regimenVersion: dose.regimenVersion,
                scheduledAt: dose.scheduledAt,
                windowEnd: dose.windowEnd,
                timingLabel: dose.timingLabel,
                timingID: dose.timingID,
                isCompleted: dose.completedAt != nil,
                isUntouched: dose.isUntouched,
                clockTimeZoneIdentifier: dose.clockTimeZoneIdentifier
            )
        }
    }

    struct Plan {
        /// Existing row → the occurrence it now represents (fields to copy, key included).
        var updates: [(UUID, GeneratedDoseOccurrence)] = []
        var inserts: [GeneratedDoseOccurrence] = []
        var deletes: [UUID] = []
    }

    static func plan(
        existing: [Row],
        generated: [GeneratedDoseOccurrence],
        currentVersion: Int,
        rangeStart: Date,
        rangeEnd: Date,
        now: Date,
        calendar: Calendar
    ) -> Plan {
        var plan = Plan()
        var matched = Set<UUID>()
        var pending: [GeneratedDoseOccurrence] = []

        // 1. Exact keys.
        var byKey: [String: Row] = [:]
        for row in existing { byKey[row.occurrenceKey] = row }
        for occurrence in generated {
            if let row = byKey[occurrence.occurrenceKey], !matched.contains(row.id) {
                matched.insert(row.id)
                plan.updates.append((row.id, occurrence))
            } else {
                pending.append(occurrence)
            }
        }

        // 2. Same slot, same day — the day on each side's own clock.
        let rowDays = Dictionary(uniqueKeysWithValues: existing.map {
            ($0.id, Self.day(of: $0.scheduledAt, clock: $0.clockTimeZoneIdentifier, home: calendar))
        })
        func day(of occurrence: GeneratedDoseOccurrence) -> DateComponents {
            Self.day(of: occurrence.scheduledAt, clock: occurrence.clockTimeZoneIdentifier, home: calendar)
        }
        var remaining: [GeneratedDoseOccurrence] = []
        for occurrence in pending {
            let occurrenceDay = day(of: occurrence)
            let sameDay = existing.filter { !matched.contains($0.id) && rowDays[$0.id] == occurrenceDay }
            let candidate =
                sameDay.first { $0.timingID != nil && $0.timingID == occurrence.timingID }
                ?? sameDay.first { $0.timingID == nil && $0.timingLabel == occurrence.timingLabel }
                ?? sameDay.first { $0.scheduledAt == occurrence.scheduledAt }
            guard let candidate else {
                remaining.append(occurrence)
                continue
            }
            matched.insert(candidate.id)
            // A completed candidate absorbs the occurrence: nothing to insert.
            guard !candidate.isCompleted else { continue }
            // Moving to another clock only while the dose stays takeable there: never into
            // a window that has already closed.
            if candidate.clockTimeZoneIdentifier != occurrence.clockTimeZoneIdentifier, occurrence.windowEnd < now {
                continue
            }
            plan.updates.append((candidate.id, occurrence))
        }

        // 3. Completed rows with no slot left still count against their day.
        var leftoverCompletedByDay: [DateComponents: Int] = [:]
        for row in existing where !matched.contains(row.id) && row.isCompleted {
            leftoverCompletedByDay[rowDays[row.id] ?? DateComponents(), default: 0] += 1
        }
        for occurrence in remaining.sorted(by: { $0.scheduledAt < $1.scheduledAt }) {
            let occurrenceDay = day(of: occurrence)
            if let count = leftoverCompletedByDay[occurrenceDay], count > 0 {
                leftoverCompletedByDay[occurrenceDay] = count - 1
                continue
            }
            plan.inserts.append(occurrence)
        }

        // Prune.
        for row in existing where !matched.contains(row.id) && row.isUntouched {
            let inRange = row.scheduledAt >= rangeStart && row.scheduledAt <= rangeEnd
            guard inRange else { continue }
            if row.regimenVersion == currentVersion || row.windowEnd >= now {
                plan.deletes.append(row.id)
            }
        }

        return plan
    }

    /// The calendar date `date` falls on, on `clock`'s clock (nil = the home calendar's).
    static func day(of date: Date, clock: String?, home: Calendar) -> DateComponents {
        var calendar = home
        if let clock, let zone = TimeZone(identifier: clock) {
            calendar.timeZone = zone
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return DateComponents(year: components.year, month: components.month, day: components.day)
    }
}
