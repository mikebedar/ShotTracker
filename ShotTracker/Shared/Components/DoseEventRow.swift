import SwiftUI

/// A single logged dose action. Shared by the global History tab and a medication's
/// own history drill-down. `showMedicationName` is off in the per-med view where the
/// name is redundant.
struct DoseEventRow: View {
    let event: DoseEvent
    var showMedicationName: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showMedicationName {
                Text(event.medication?.displayName ?? "Medication")
                    .font(.headline)
                if let canonicalName = event.medication.flatMap(AppFormatting.medicationSubtitle(for:)) {
                    Text(canonicalName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            // "Taken 45 min late · snoozed 30 min", "Snoozed 20 min" — see `SnoozeWording`.
            Text(title)
                .font(.subheadline.weight(.medium))
                .accessibilityLabel(SnoozeWording.spoken(title))
            Text(times.dateTime(event.loggedAt))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(event.loggedAt.formatted(date: .abbreviated, time: .omitted)), \(times.spokenTime(event.loggedAt))")
            if !event.note.isEmpty {
                Text(event.note)
                    .font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        SnoozeWording.eventTitle(for: event)
    }

    /// The medication's home clock, plus the local one when the device is elsewhere.
    private var times: ZonedTimeFormatter {
        let home = event.scheduledDose?.homeTimeZone ?? event.medication?.homeTimeZone()
        return ZonedTimeFormatter(home: home)
    }
}
