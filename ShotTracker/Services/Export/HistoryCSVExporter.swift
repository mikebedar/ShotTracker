import Foundation

/// Builds a CSV of the full dose + refill history — the "bring to your doctor" export.
/// Pure string assembly, unit-testable without SwiftData.
enum HistoryCSVExporter {
    static func csv(doseEvents: [DoseEvent], refillEvents: [RefillEvent]) -> String {
        var rows: [(date: Date, columns: [String])] = []

        for event in doseEvents {
            rows.append((event.loggedAt, [
                dateString(event.loggedAt),
                timeString(event.loggedAt),
                event.medication?.displayName ?? "",
                event.action.historyTitle,
                event.scheduledDose.map { scheduledForString($0) } ?? "",
                event.note,
            ]))
        }

        for refill in refillEvents {
            rows.append((refill.loggedAt, [
                dateString(refill.loggedAt),
                timeString(refill.loggedAt),
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

    private static func scheduledForString(_ dose: ScheduledDose) -> String {
        "Scheduled \(dateString(dose.scheduledAt)) \(timeString(dose.scheduledAt)) (\(dose.slotTitle))"
    }

    private static func dateString(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private static func timeString(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// RFC-4180 escaping: quote any field containing a comma, quote, or newline.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
