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

        init(id: UUID, occurrenceKey: String, regimenVersion: Int, scheduledAt: Date, windowEnd: Date,
             timingLabel: String, timingID: UUID?, isCompleted: Bool, isUntouched: Bool) {
            self.id = id
            self.occurrenceKey = occurrenceKey
            self.regimenVersion = regimenVersion
            self.scheduledAt = scheduledAt
            self.windowEnd = windowEnd
            self.timingLabel = timingLabel
            self.timingID = timingID
            self.isCompleted = isCompleted
            self.isUntouched = isUntouched
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
                isUntouched: dose.isUntouched
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

        // 2. Same slot, same day.
        var remaining: [GeneratedDoseOccurrence] = []
        for occurrence in pending {
            let day = calendar.startOfDay(for: occurrence.scheduledAt)
            let sameDay = existing.filter {
                !matched.contains($0.id) && calendar.isDate($0.scheduledAt, inSameDayAs: day)
            }
            let candidate =
                sameDay.first { $0.timingID != nil && $0.timingID == occurrence.timingID }
                ?? sameDay.first { $0.timingID == nil && $0.timingLabel == occurrence.timingLabel }
                ?? sameDay.first { $0.scheduledAt == occurrence.scheduledAt }
            guard let candidate else {
                remaining.append(occurrence)
                continue
            }
            matched.insert(candidate.id)
            if !candidate.isCompleted {
                plan.updates.append((candidate.id, occurrence))
            }
            // A completed candidate absorbs the occurrence: nothing to insert.
        }

        // 3. Completed rows with no slot left still count against their day.
        var leftoverCompletedByDay: [Date: Int] = [:]
        for row in existing where !matched.contains(row.id) && row.isCompleted {
            leftoverCompletedByDay[calendar.startOfDay(for: row.scheduledAt), default: 0] += 1
        }
        for occurrence in remaining.sorted(by: { $0.scheduledAt < $1.scheduledAt }) {
            let day = calendar.startOfDay(for: occurrence.scheduledAt)
            if let count = leftoverCompletedByDay[day], count > 0 {
                leftoverCompletedByDay[day] = count - 1
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
}
