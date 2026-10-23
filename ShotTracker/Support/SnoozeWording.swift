import Foundation

/// How snoozes and lateness read in Today, history, the CSV and notifications. One place,
/// so a dose card, its history row and the export never word the same dose differently.
///
/// - A snooze event: "Snoozed 20 min" ("Snoozed 20 min · 40 min in all" after a second).
/// - A taken dose: "Taken on time" / "Taken 45 min late", plus "· snoozed 30 min" when it
///   was snoozed first. Late is measured from the original window's end: a snooze moves
///   the deadline (when the dose turns overdue), not what counts as on time.
nonisolated enum SnoozeWording {
    /// "20 min", "1 hr 5 min".
    static func duration(minutes: Int) -> String {
        let minutes = max(0, minutes)
        return Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, zeroValueUnits: .hide)
        )
        .replacingOccurrences(of: ",", with: "")
    }

    /// The history / CSV line for a logged event. Events from before offsets were tracked
    /// (nil fields) keep the plain action title.
    @MainActor
    static func eventTitle(for event: DoseEvent) -> String {
        switch event.action {
        case .snoozed:
            guard let minutes = event.snoozeMinutes else { return event.action.historyTitle }
            var text = "Snoozed \(duration(minutes: minutes))"
            if let total = event.snoozeOffsetMinutes, total > minutes {
                text += " · \(duration(minutes: total)) in all"
            }
            return text
        case .taken:
            guard let late = event.minutesLate else { return event.action.historyTitle }
            return takenText(minutesLate: late, snoozeMinutes: event.snoozeOffsetMinutes ?? 0)
        case .skipped, .pending:
            return event.action.historyTitle
        }
    }

    /// "Taken on time", "Taken 45 min late · snoozed 30 min".
    static func takenText(minutesLate: Int, snoozeMinutes: Int) -> String {
        var text = minutesLate > 0 ? "Taken \(duration(minutes: minutesLate)) late" : "Taken on time"
        if snoozeMinutes > 0 {
            text += " · snoozed \(duration(minutes: snoozeMinutes))"
        }
        return text
    }

    /// Spoken form of `takenText`/`eventTitle` — the "·" separator reads as nothing.
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: " · ", with: ", ")
    }
}
