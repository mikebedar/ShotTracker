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
                    Text(clockText.point(dose.scheduledAt))
                        .accessibilityLabel(clockText.spokenPoint(dose.scheduledAt))
                }
                .font(Theme.Font.text(.footnote))
                .foregroundStyle(Theme.Color.textSecondary)

                if let detail = clockText.detail(dose.scheduledAt) {
                    Text(detail)
                        .font(Theme.Font.text(.caption))
                        .foregroundStyle(Theme.Color.textTertiary)
                        .accessibilityHidden(true)
                }

                if dose.snoozeOffset > 0 {
                    Text(snoozeDetail)
                        .font(Theme.Font.text(.caption))
                        .foregroundStyle(Theme.Color.textTertiary)
                        .accessibilityLabel(SnoozeWording.spoken(snoozeDetail))
                }
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

    @Environment(\.dayParts) private var dayParts

    /// "6:00 AM" at home; away, "Morning (Paris) · 6:00 AM" + "Home: Night · 12:00 AM" for
    /// a slot and "8:00 AM home · 2:00 PM here" for a specific time. A forecast dose has
    /// no `medication` relationship, so the zone comes from the medication passed in.
    private var clockText: DoseClockText {
        DoseClockText(dose: dose, medication: medication, dayParts: dayParts)
    }

    /// "Snoozed 20 min" on an open dose, "Taken 10 min late · snoozed 20 min" on a taken one.
    private var snoozeDetail: String {
        if dose.lastAction == .taken {
            return SnoozeWording.takenText(minutesLate: dose.minutesLate, snoozeMinutes: dose.snoozeOffset)
        }
        return "Snoozed \(SnoozeWording.duration(minutes: dose.snoozeOffset))"
    }
}
