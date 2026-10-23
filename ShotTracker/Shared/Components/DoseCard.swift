import SwiftUI

/// Primary dose card: artwork + name + status pill, an action bar when actionable
/// (due/overdue), a "Logged"/Undo footer when resolved (taken/skipped), and an
/// optional supply row. Presentational only — callers own the `AppDependencies`
/// calls behind the action closures.
struct DoseCard: View {
    let dose: ScheduledDose
    let status: DoseStatus
    var onTake: (() -> Void)?
    var onSnooze: (() -> Void)?
    var onSkip: (() -> Void)?
    var onUndo: (() -> Void)?

    private var medication: Medication? { dose.medication }
    private var medicationName: String { medication?.displayName ?? "Medication" }
    private var canonicalName: String? { medication.flatMap(AppFormatting.medicationSubtitle(for:)) }
    // Any dose that hasn't been taken or skipped is takeable — including an upcoming one
    // earlier in the day. DoseCard is only shown for today's doses (TodayView buckets), so
    // this enables taking a "Later Today"/"Tonight" dose now without exposing actions on
    // far-future forecast rows (those use ComingUpRow/SimpleDoseRow).
    private var isActionable: Bool { !isResolved }
    private var isResolved: Bool { status == .takenOnTime || status == .takenLate || status == .skipped }
    private var isOverdue: Bool { status == .overdue }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s3) {
            header

            if isActionable, let onTake, let onSkip {
                DoseActionBar(doseID: dose.id, status: status, onTake: onTake, onSnooze: onSnooze, onSkip: onSkip)
            }

            if isResolved {
                resolvedFooter
            }

            if let medication, medication.isTrackingSupply, let unitLabel = medication.supplyUnitLabel {
                SupplyRow(
                    currentContainerRemaining: medication.currentContainerRemaining,
                    unitsPerContainer: medication.unitsPerContainer ?? medication.totalRemaining,
                    totalRemaining: medication.totalRemaining,
                    unitLabel: unitLabel,
                    containerNoun: medication.kind.containerNoun,
                    isLow: medication.isSupplyLow
                )
            }
        }
        .padding(Theme.Spacing.s4)
        .background(cardBackground)
        .themedBorder(
            color: isOverdue ? Theme.Color.statusOverdue : Theme.Color.border,
            strongColor: isOverdue ? Theme.Color.statusOverdue : Theme.Color.borderStrong,
            cornerRadius: Theme.Radius.card
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.s3) {
            if let medication {
                MedicationArtworkView(medication: medication)
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.avatar, style: .continuous)
                    .fill(Theme.Color.surfaceSecondary)
                    .frame(width: 44, height: 44)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(medicationName)
                    .font(Theme.Font.display(.headline))
                    .foregroundStyle(Theme.Color.textPrimary)

                if let canonicalName {
                    Text(canonicalName)
                        .font(Theme.Font.text(.footnote))
                        .foregroundStyle(Theme.Color.textTertiary)
                }

                HStack(spacing: 5) {
                    Image(systemName: (medication?.kind ?? .oral).symbolName)
                        .font(.caption)
                    Text(timingText)
                }
                .font(Theme.Font.text(.subheadline))
                .foregroundStyle(Theme.Color.textSecondary)

                if medication?.takeWithFood == true {
                    Label("Take with food", systemImage: "fork.knife")
                        .font(Theme.Font.text(.footnote))
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }

            Spacer(minLength: Theme.Spacing.s3)

            StatusPill(status: status)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Row-level identifier lives here, not on the outer card: putting it on a
        // container that also encloses DoseActionBar's buttons causes those buttons'
        // own identifiers to be overridden by this one in the XCUITest accessibility
        // tree (verified via a live accessibility-hierarchy dump).
        .accessibilityIdentifier(AccessibilityID.scheduledDoseRow(dose.id))
    }

    private var timingText: String {
        if dose.isFlexibleWindow {
            // "Morning · anytime by 12:00 PM"
            return "\(dose.slotTitle) · anytime by \(dose.windowEnd.formatted(date: .omitted, time: .shortened))"
        }
        // A precise dose: its slot *is* its time ("At 9:02 AM").
        return "At \(dose.scheduledAt.formatted(date: .omitted, time: .shortened))"
    }

    private var resolvedFooter: some View {
        HStack {
            Text(footerText)
                .font(Theme.Font.text(.footnote))
                .foregroundStyle(Theme.Color.textTertiary)

            Spacer()

            if let onUndo {
                Button("Undo", action: onUndo)
                    .font(Theme.Font.text(.footnote).weight(.bold))
                    .foregroundStyle(Theme.Color.accentStrong)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier(AccessibilityID.undoDoseButton(dose.id))
                    .accessibilityHint("Reverts this dose to not logged.")
            }
        }
    }

    private var footerText: String {
        if status == .skipped {
            return "Skipped · \(dose.scheduledAt.formatted(date: .omitted, time: .shortened))"
        }
        if let completedAt = dose.completedAt {
            return "Logged at \(completedAt.formatted(date: .omitted, time: .shortened))"
        }
        return status.title
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isOverdue {
            LinearGradient(
                colors: [Theme.Color.statusOverdueSoft, Theme.Color.surface],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Theme.Color.surface
        }
    }

    private var accessibilityLabel: String {
        var parts = ["\(medicationName), \(status.title.lowercased()), \(timingText)."]
        if isActionable {
            parts.append(onSnooze == nil ? "Actions: Take, Skip." : "Actions: Take, Snooze, Skip.")
        } else if isResolved, onUndo != nil {
            parts.append("Double tap Undo to revert.")
        }
        return parts.joined(separator: " ")
    }
}
