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
/// absorbs the new occurrence (no second "Morning" that day). A row whose window is open
/// right now stays on its clock until that window closes (an evening dose due over the
/// Atlantic stays on New York's clock; flying west, a morning open in Paris stays on
/// Paris's clock rather than jump to New York's later morning), and nothing moves into a
/// window that has already closed on the new clock: a zone change never moves a takeable
/// dose into the past, and a missed dose stays as it was recorded — unless its slot is
/// still ahead on the new clock (flying west: the morning missed in Paris is still to
/// come in New York, the same local day). Rows not yet open move freely.
///
/// **Travel options (2026-10-23, `TravelRules`, per regimen).** *Landing during a dose*:
/// `.finishOnOldClock` is the rule above; with `.moveNow` an open row (its own window not
/// closed yet: open now, or still ahead) moves to the new clock's same-day slot even when
/// that window has already closed there (then it is overdue there, "Morning (Paris)",
/// late); a row whose own window already closed keeps the rule above.
///
/// *Long trips & date lines*: `.calendarDay` is the slot + local day identity above. In
/// hours mode (`minimumHours` N), for a slot that follows the device, let L be the latest
/// **taken** dose of that slot (any version; slot = `timingID`, else label). An occurrence
/// of the slot is *after a clock change* when its clock differs from L's row's clock (nil =
/// home) and its window ends after L was taken. Such an occurrence is judged by hours, not
/// by date:
/// - its window ends within N hours of L → **covered**: no dose. An untouched row of it
///   is deleted; a same-day row on the old clock that is history stays, one open now (or
///   ahead while the covered window has already closed) is held there when finishing on
///   the old clock, and goes otherwise (with `.moveNow`, or when it hasn't opened yet);
/// - else, if it opens less than N hours after L → **held**: it opens at L + N (reminder no
///   earlier), `spacingHoldHours` = N; the key keeps the usual start so the plan stays
///   idempotent and an Undo of L puts the usual window back;
/// - either way the date doesn't absorb it: rows completed at or before L don't match it
///   in step 2 and don't use up its day in step 3. So a date lived twice (Tokyo → New
///   York) can have its slot again if its window reaches N hours after L, and a date
///   skipped (west over the date line) costs nothing — the first window that ends N hours
///   after L is offered, once.
/// Everything that ends before L, and everything once a dose has been taken on the new
/// clock (L's clock is then the same), follows the calendar-day rules. At home nothing
/// changes (one clock).
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
        /// When it was taken or skipped (nil while open).
        let completedAt: Date?
        /// Taken (not skipped): what hours mode measures from.
        let isTaken: Bool

        init(id: UUID, occurrenceKey: String, regimenVersion: Int, scheduledAt: Date, windowEnd: Date,
             timingLabel: String, timingID: UUID?, isCompleted: Bool, isUntouched: Bool,
             clockTimeZoneIdentifier: String? = nil, completedAt: Date? = nil, isTaken: Bool = false) {
            self.completedAt = completedAt
            self.isTaken = isTaken
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
                clockTimeZoneIdentifier: dose.clockTimeZoneIdentifier,
                completedAt: dose.completedAt,
                isTaken: dose.lastAction == .taken && dose.completedAt != nil
            )
        }
    }

    struct Plan {
        /// Existing row → the occurrence it now represents (fields to copy, key included).
        var updates: [(UUID, GeneratedDoseOccurrence)] = []
        var inserts: [GeneratedDoseOccurrence] = []
        var deletes: [UUID] = []
    }

    /// A regimen's travel options as the plan uses them.
    struct TravelRules {
        var landing: TravelLanding = .finishOnOldClock
        /// Hours mode's N; nil = count by calendar day.
        var minimumHours: Int? = nil
        /// The slots that follow the device (hours mode applies only to them).
        var followingTimingIDs: Set<UUID> = []
        var followingLabels: Set<String> = []

        init(landing: TravelLanding = .finishOnOldClock, minimumHours: Int? = nil,
             followingTimingIDs: Set<UUID> = [], followingLabels: Set<String> = []) {
            self.landing = landing
            self.minimumHours = minimumHours
            self.followingTimingIDs = followingTimingIDs
            self.followingLabels = followingLabels
        }

        /// The rules of `regimen` (its timings, or the engine's fallback when it has none).
        init(regimen: MedicationRegimen) {
            let timings = regimen.timings.isEmpty ? [DoseScheduleEngine.fallbackTiming] : regimen.timings
            let following = timings.filter { regimen.travelPolicy(for: $0) == .followsMe }
            landing = regimen.travelLanding
            minimumHours = regimen.travelSpacing == .minimumHours ? regimen.effectiveTravelMinimumHours : nil
            followingTimingIDs = Set(following.map(\.id))
            followingLabels = Set(following.map(\.slotLabel))
        }

        func follows(_ occurrence: GeneratedDoseOccurrence) -> Bool {
            if let id = occurrence.timingID { return followingTimingIDs.contains(id) }
            return followingLabels.contains(occurrence.timingLabel)
        }
    }

    /// The whole refresh of one regimen, on plain values: generate on `engine`'s device
    /// clock and diff against `existing`. `DoseRepository.refreshSchedules` applies it to
    /// the store; `TravelExample` applies it to a simulated trip, so the example runs the
    /// same code as the app.
    static func refreshPlan(
        existing: [Row],
        regimen: MedicationRegimen,
        medicationID: UUID,
        lastTaken: DoseRescheduling.LastTakenDose?,
        engine: DoseScheduleEngine,
        preferences: AppPreferences,
        referenceDate: Date,
        horizonDays: Int = DoseRepository.materializationLookaheadDays
    ) -> Plan {
        let utc = Calendar(identifier: .gregorian)
        let start = utc.date(byAdding: .day, value: -DoseRepository.materializationLookbackDays, to: referenceDate) ?? referenceDate
        let end = utc.date(byAdding: .day, value: horizonDays, to: referenceDate) ?? referenceDate
        let generated = engine.generateOccurrences(
            regimen: regimen,
            medicationID: medicationID,
            inputs: DoseRescheduling.engineInputs(regimen: regimen, lastTaken: lastTaken),
            from: start,
            through: end,
            preferences: preferences
        )
        var regimenCalendar = Calendar(identifier: .gregorian)
        regimenCalendar.timeZone = regimen.homeTimeZone
        // Travelling, the slots that follow the device start their range at the device's
        // midnight: prune only where both clocks generated.
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = engine.deviceTimeZone(home: regimen.homeTimeZone)
        return plan(
            existing: existing,
            generated: generated,
            currentVersion: regimen.version,
            rangeStart: max(regimenCalendar.startOfDay(for: start), deviceCalendar.startOfDay(for: start)),
            rangeEnd: end,
            now: referenceDate,
            calendar: regimenCalendar,
            rules: TravelRules(regimen: regimen)
        )
    }

    static func plan(
        existing: [Row],
        generated originalGenerated: [GeneratedDoseOccurrence],
        currentVersion: Int,
        rangeStart: Date,
        rangeEnd: Date,
        now: Date,
        calendar: Calendar,
        rules: TravelRules = TravelRules()
    ) -> Plan {
        var plan = Plan()
        var matched = Set<UUID>()
        var pending: [GeneratedDoseOccurrence] = []
        let homeID = calendar.timeZone.identifier

        // 0. Hours mode: occurrences after a clock change are judged by the hours since
        //    their slot's last dose (covered / held), not by their date.
        var generated = originalGenerated
        var covered = Set<String>()
        var lastDoseBefore: [String: Date] = [:]  // occurrence key → its slot's last dose
        if let hours = rules.minimumHours {
            let taken = existing.filter { $0.isTaken && $0.completedAt != nil }
            for index in generated.indices where rules.follows(generated[index]) {
                let occurrence = generated[index]
                let sameSlot = taken.filter { row in
                    if let id = occurrence.timingID, row.timingID != nil { return row.timingID == id }
                    return row.timingLabel == occurrence.timingLabel
                }
                guard let last = sameSlot.max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }),
                      let lastAt = last.completedAt,
                      (last.clockTimeZoneIdentifier ?? homeID) != (occurrence.clockTimeZoneIdentifier ?? homeID),
                      occurrence.windowEnd > lastAt
                else { continue }
                lastDoseBefore[occurrence.occurrenceKey] = lastAt
                let earliest = lastAt.addingTimeInterval(TimeInterval(hours * 3600))
                if occurrence.windowEnd <= earliest {
                    covered.insert(occurrence.occurrenceKey)
                } else if occurrence.scheduledAt < earliest {
                    generated[index] = occurrence.held(until: earliest, hours: hours)
                }
            }
        }

        // 1. Exact keys.
        var byKey: [String: Row] = [:]
        for row in existing { byKey[row.occurrenceKey] = row }
        for occurrence in generated {
            if let row = byKey[occurrence.occurrenceKey], !matched.contains(row.id) {
                matched.insert(row.id)
                if covered.contains(occurrence.occurrenceKey) {
                    // The last dose covers this window: no dose here.
                    if row.isUntouched { plan.deletes.append(row.id) }
                    continue
                }
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
            let isCovered = covered.contains(occurrence.occurrenceKey)
            let lastDose = lastDoseBefore[occurrence.occurrenceKey]
            let sameDay = existing.filter { row in
                guard !matched.contains(row.id), rowDays[row.id] == occurrenceDay else { return false }
                // Hours mode: a dose taken (or skipped) before the slot's last dose doesn't
                // stand for an occurrence after a clock change; only the hours do.
                if let lastDose, row.isCompleted, let completedAt = row.completedAt, completedAt <= lastDose { return false }
                return true
            }
            let candidate =
                sameDay.first { $0.timingID != nil && $0.timingID == occurrence.timingID }
                ?? sameDay.first { $0.timingID == nil && $0.timingLabel == occurrence.timingLabel }
                ?? sameDay.first { $0.scheduledAt == occurrence.scheduledAt }
            guard let candidate else {
                if !isCovered { remaining.append(occurrence) }
                continue
            }
            matched.insert(candidate.id)
            // A completed candidate absorbs the occurrence: nothing to insert.
            guard !candidate.isCompleted else { continue }
            let changesClock = candidate.clockTimeZoneIdentifier != occurrence.clockTimeZoneIdentifier
            // The row's own window is open right now (on its clock).
            let isOpenNow = candidate.scheduledAt <= now && candidate.windowEnd >= now
            if isCovered {
                // Never onto a covered window. A row on the old clock that is history (its
                // window closed) stays; one still open — or ahead while the covered window
                // has closed — stays there when finishing on the old clock; anything else
                // untouched goes (the last dose covers it).
                if changesClock, candidate.windowEnd < now { continue }
                if changesClock, rules.landing == .finishOnOldClock, isOpenNow || occurrence.windowEnd < now { continue }
                if candidate.isUntouched { plan.deletes.append(candidate.id) }
                continue
            }
            if changesClock {
                switch rules.landing {
                case .finishOnOldClock:
                    // An open dose finishes on its clock, and nothing moves into a window
                    // that has already closed on the new one.
                    if isOpenNow || occurrence.windowEnd < now { continue }
                case .moveNow:
                    // An open (or still ahead) dose moves at once, even into a closed
                    // window; one already missed stays as it was recorded.
                    if occurrence.windowEnd < now, candidate.windowEnd < now { continue }
                }
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
            if lastDoseBefore[occurrence.occurrenceKey] == nil, let count = leftoverCompletedByDay[occurrenceDay], count > 0 {
                leftoverCompletedByDay[occurrenceDay] = count - 1
                continue
            }
            plan.inserts.append(occurrence)
        }

        // Prune.
        let deleted = Set(plan.deletes)
        for row in existing where !matched.contains(row.id) && row.isUntouched && !deleted.contains(row.id) {
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

extension GeneratedDoseOccurrence {
    /// Hours mode: the same occurrence (same key) opening at `earliest` instead, its
    /// reminder no earlier.
    func held(until earliest: Date, hours: Int) -> GeneratedDoseOccurrence {
        var copy = GeneratedDoseOccurrence(
            occurrenceKey: occurrenceKey,
            scheduledAt: earliest,
            windowEndAt: windowEndAt,
            reminderAt: max(reminderAt, earliest),
            timingLabel: timingLabel,
            reminderWindowMinutes: reminderWindowMinutes,
            graceWindowMinutes: graceWindowMinutes,
            timingID: timingID,
            clockTimeZoneIdentifier: clockTimeZoneIdentifier
        )
        copy.spacingHoldHours = hours
        return copy
    }
}
