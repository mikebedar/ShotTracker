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
        AdaptiveStack {
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

            Spacer(minLength: 0)

            // The group header already names the day.
            Text(times.time(dose.scheduledAt))
                .font(Theme.Font.text(.footnote).weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(times.spokenTime(dose.scheduledAt))
        }
        .padding(.vertical, Theme.Spacing.s2)
        .opacity(isForecasted ? 0.65 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.scheduledDoseRow(dose.id))
    }

    /// Home clock, plus the local one when the device is in another zone.
    private var times: ZonedTimeFormatter {
        ZonedTimeFormatter(home: medication?.homeTimeZone(forVersion: dose.regimenVersion))
    }
}
