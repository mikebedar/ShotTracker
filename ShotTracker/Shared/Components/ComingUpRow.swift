import SwiftUI

/// Minimal row for the long-range "Coming Up" list — icon + name + time only, no
/// status pill (every item here is `.upcoming` by construction). `medication` is taken
/// explicitly (not derived from `dose.medication`) so this can render forecasted,
/// non-persisted doses too — see `DoseForecastService`.
struct ComingUpRow: View {
    let dose: ScheduledDose
    let medication: Medication?
    var isForecasted: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.s3) {
            Image(systemName: (medication?.kind ?? .oral).symbolName)
                .foregroundStyle(Theme.Color.textTertiary)

            VStack(alignment: .leading, spacing: 1) {
                Text(medication?.displayName ?? "Medication")
                    .font(Theme.Font.display(.subheadline))
                    .foregroundStyle(Theme.Color.textPrimary)

                if let canonicalName = medication.flatMap(AppFormatting.medicationSubtitle(for:)) {
                    Text(canonicalName)
                        .font(Theme.Font.text(.caption))
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }

            Spacer(minLength: Theme.Spacing.s3)

            Text(dose.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                .font(Theme.Font.text(.footnote).weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.vertical, Theme.Spacing.s2)
        .opacity(isForecasted ? 0.65 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.scheduledDoseRow(dose.id))
    }
}
