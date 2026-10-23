import SwiftUI

/// Condensed single-line dose row (artwork + name + time + compact status pill),
/// used for lower-priority items like "Tomorrow" or a selected calendar day.
/// `medication` is taken explicitly (not derived from `dose.medication`) so this can
/// render forecasted, non-persisted doses too — see `DoseForecastService`.
struct SimpleDoseRow: View {
    let dose: ScheduledDose
    let medication: Medication?
    let status: DoseStatus
    var isForecasted: Bool = false

    var body: some View {
        AdaptiveStack {
            if let medication {
                MedicationArtworkView(medication: medication, size: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(medication?.displayName ?? "Medication")
                    .font(Theme.Font.display(.subheadline))
                    .foregroundStyle(Theme.Color.textPrimary)

                HStack(spacing: 5) {
                    Image(systemName: (medication?.kind ?? .oral).symbolName)
                        .font(.caption2)
                    Text(dose.scheduledAt.formatted(date: .omitted, time: .shortened))
                }
                .font(Theme.Font.text(.footnote))
                .foregroundStyle(Theme.Color.textSecondary)
            }

            Spacer(minLength: 0)

            StatusPill(status: status, style: .compact)
        }
        .padding(Theme.Spacing.s3)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .themedBorder(cornerRadius: 15)
        .opacity(isForecasted ? 0.65 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.scheduledDoseRow(dose.id))
    }
}
