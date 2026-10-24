import Foundation

/// Builds a CSV of the full dose + refill history — the "bring to your doctor" export.
/// Pure string assembly, unit-testable without SwiftData.
enum HistoryCSVExporter {
    /// The Date, Time and Time Zone columns are when the action was logged, on the clock
    /// it was logged on (`DoseEvent.timeZoneIdentifier`; `timeZone`, the device's, for
    /// refills and events from before zones were recorded). A dose scheduled in another
    /// home zone names both zones in its Detail ("Scheduled 2026-10-23 8:00 AM EDT (2:00 PM
    /// GMT+2 local)"); a slot that followed the device names its clock and home's
    /// ("Scheduled 2026-10-23 6:00 AM GMT+2 (Morning (Paris); Home: Night · 12:00 AM EDT)").
    static func csv(
        doseEvents: [DoseEvent],
        refillEvents: [RefillEvent],
        timeZone: TimeZone = .current,
        dayParts: DayParts = .standard
    ) -> String {
        var rows: [(date: Date, columns: [String])] = []

        for event in doseEvents {
            let zone = event.timeZone ?? timeZone
            rows.append((event.loggedAt, [
                dateString(event.loggedAt, timeZone: zone),
                timeString(event.loggedAt, timeZone: zone),
                ZonedTimeFormatter.abbreviation(of: zone, at: event.loggedAt),
                event.medication?.displayName ?? "",
                // "Taken 45 min late · snoozed 30 min", "Snoozed 20 min", "Undone".
                SnoozeWording.eventTitle(for: event),
                event.scheduledDose.map { scheduledForString($0, event: event, timeZone: zone, dayParts: dayParts) } ?? "",
                event.note,
            ]))
        }

        for refill in refillEvents {
            rows.append((refill.loggedAt, [
                dateString(refill.loggedAt, timeZone: timeZone),
                timeString(refill.loggedAt, timeZone: timeZone),
                ZonedTimeFormatter.abbreviation(of: timeZone, at: refill.loggedAt),
                refill.medication?.displayName ?? "",
                "Refill",
                "+\(refill.quantity) \(refill.medication?.supplyUnitLabel ?? "units")",
                refill.note,
            ]))
        }

        rows.sort { $0.date > $1.date }

        let header = ["Date", "Time", "Time Zone", "Medication", "Event", "Detail", "Note"]
        let lines = [header] + rows.map(\.columns)
        return lines.map { line in
            line.map { escape($0) }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    /// "Scheduled 2026-10-23 8:00 AM (Morning)"; when the dose's home zone isn't the
    /// local one, the date is the home date and both clocks are named.
    private static func scheduledForString(_ dose: ScheduledDose, event: DoseEvent, timeZone: TimeZone, dayParts: DayParts) -> String {
        let clockText = DoseClockText(dose: dose, medication: event.medication, dayParts: dayParts, device: timeZone)
        if let slot = clockText.awaySlot, let otherZone = slot.otherZone, let detail = slot.detail(dose.scheduledAt) {
            let clockTime = slot.time(dose.scheduledAt) + " " + ZonedTimeFormatter.abbreviation(of: slot.clock, at: dose.scheduledAt)
            let other = detail + " " + ZonedTimeFormatter.abbreviation(of: otherZone, at: dose.scheduledAt)
            return "Scheduled \(dateString(dose.scheduledAt, timeZone: slot.clock)) \(clockTime) (\(slot.title); \(other))"
        }
        let times = ZonedTimeFormatter(home: dose.homeTimeZone, local: timeZone)
        let dateZone = times.differs(at: dose.scheduledAt) ? times.home : timeZone
        return "Scheduled \(dateString(dose.scheduledAt, timeZone: dateZone)) \(times.timeWithZoneNames(dose.scheduledAt)) (\(dose.slotTitle))"
    }

    /// The calendar date on `timeZone`'s clock. (`.iso8601` alone formats in UTC, so an
    /// evening dose in California used to export under the next day's date.)
    private static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().dateSeparator(.dash))
    }

    private static func timeString(_ date: Date, timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// RFC-4180 escaping: quote any field containing a comma, quote, or newline.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
