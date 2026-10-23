import Foundation

/// Builds a CSV of the full dose + refill history — the "bring to your doctor" export.
/// Pure string assembly, unit-testable without SwiftData.
enum HistoryCSVExporter {
    /// `timeZone` is the device's: the Date and Time columns are when the action was
    /// logged, on the local clock. A dose scheduled in another home zone names both
    /// zones in its Detail ("Scheduled 2026-10-23 8:00 AM EDT (2:00 PM GMT+2 local)").
    static func csv(doseEvents: [DoseEvent], refillEvents: [RefillEvent], timeZone: TimeZone = .current) -> String {
        var rows: [(date: Date, columns: [String])] = []

        for event in doseEvents {
            rows.append((event.loggedAt, [
                dateString(event.loggedAt, timeZone: timeZone),
                timeString(event.loggedAt, timeZone: timeZone),
                event.medication?.displayName ?? "",
                // "Taken 45 min late · snoozed 30 min", "Snoozed 20 min", "Undone".
                SnoozeWording.eventTitle(for: event),
                event.scheduledDose.map { scheduledForString($0, timeZone: timeZone) } ?? "",
                event.note,
            ]))
        }

        for refill in refillEvents {
            rows.append((refill.loggedAt, [
                dateString(refill.loggedAt, timeZone: timeZone),
                timeString(refill.loggedAt, timeZone: timeZone),
                refill.medication?.displayName ?? "",
                "Refill",
                "+\(refill.quantity) \(refill.medication?.supplyUnitLabel ?? "units")",
                refill.note,
            ]))
        }

        rows.sort { $0.date > $1.date }

        let header = ["Date", "Time", "Medication", "Event", "Detail", "Note"]
        let lines = [header] + rows.map(\.columns)
        return lines.map { line in
            line.map { escape($0) }.joined(separator: ",")
        }.joined(separator: "\n")
    }

    /// "Scheduled 2026-10-23 8:00 AM (Morning)"; when the dose's home zone isn't the
    /// local one, the date is the home date and both clocks are named.
    private static func scheduledForString(_ dose: ScheduledDose, timeZone: TimeZone) -> String {
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
