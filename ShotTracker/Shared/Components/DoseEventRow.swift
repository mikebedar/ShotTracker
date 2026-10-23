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
            Text(event.action.title)
                .font(.subheadline.weight(.medium))
            Text(event.loggedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !event.note.isEmpty {
                Text(event.note)
                    .font(.subheadline)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
