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
            } else if dose.snoozeOffset > 0 {
                snoozeFooter
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    private var artwork: some View {
        if let medication {
            MedicationArtworkView(medication: medication)
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.avatar, style: .continuous)
                .fill(Theme.Color.surfaceSecondary)
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Artwork and pill on one line, the text full width below — side by side
                // the fixed-size pill left the name almost no room.
                VStack(alignment: .leading, spacing: Theme.Spacing.s2) {
                    HStack(alignment: .top) {
                        artwork
                        Spacer(minLength: Theme.Spacing.s2)
                        StatusPill(status: status)
                    }
                    details
                }
            } else {
                HStack(alignment: .top, spacing: Theme.Spacing.s3) {
                    artwork
                    details
                    Spacer(minLength: Theme.Spacing.s3)
                    StatusPill(status: status)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Row-level identifier lives here, not on the outer card: putting it on a
        // container that also encloses DoseActionBar's buttons causes those buttons'
        // own identifiers to be overridden by this one in the XCUITest accessibility
        // tree (verified via a live accessibility-hierarchy dump).
        .accessibilityIdentifier(AccessibilityID.scheduledDoseRow(dose.id))
    }

    private var details: some View {
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

                // Away from home, a slot's other clock: "Home: Night · by 6:00 AM".
                if let timingDetail {
                    Text(timingDetail)
                        .font(Theme.Font.text(.footnote))
                        .foregroundStyle(Theme.Color.textTertiary)
                }

                if medication?.takeWithFood == true {
                    Label("Take with food", systemImage: "fork.knife")
                        .font(Theme.Font.text(.footnote))
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
    }

    @Environment(\.dayParts) private var dayParts

    /// Which clock the dose is on and how its times read (`DoseClockText`).
    private var clockText: DoseClockText {
        DoseClockText(dose: dose, dayParts: dayParts)
    }

    /// Footer and snooze times: the local clock for a slot that follows the device, else
    /// home and (when the device is elsewhere) here.
    private var times: ZonedTimeFormatter {
        clockText.times
    }

    private var timingText: String {
        let clock = clockText
        if let slot = clock.awaySlot {
            // "Morning (Paris) · anytime by 12:00 PM" — on the slot's own clock.
            return String(localized: "\(slot.title) · anytime by \(slot.time(dose.deadline))", comment: "A dose slot away from home and its deadline on its own clock")
        }
        return timingText(time: clock.times.time)
    }

    private var timingDetail: String? {
        clockText.detail(dose.deadline, by: true)
    }

    private var spokenTimingText: String {
        let clock = clockText
        if let slot = clock.awaySlot {
            // "Morning in Paris, anytime by 12:00 PM; at home it's night, by 6:00 AM"
            return clock.spoken(
                slot: slot,
                time: String(localized: "anytime by \(slot.time(dose.deadline))", comment: "Spoken dose deadline"),
                detail: slot.spokenDetail(dose.deadline, by: true)
            )
        }
        return timingText(time: clock.times.spokenTime)
    }

    private func timingText(time: (Date) -> String) -> String {
        if dose.isFlexibleWindow {
            // "Morning · anytime by 12:00 PM" (a snooze moves the deadline: "by 12:20 PM")
            return "\(dose.slotTitle) · anytime by \(time(dose.deadline))"
        }
        // A precise dose: its slot *is* its time ("At 9:02 AM").
        return "At \(time(dose.scheduledAt))"
    }

    private var resolvedFooter: some View {
        // Stacks at AX sizes: beside Undo, a long footer broke mid-word.
        AdaptiveStack(spacing: Theme.Spacing.s2) {
            Text(footerText)
                .font(Theme.Font.text(.footnote))
                .foregroundStyle(Theme.Color.textTertiary)

            Spacer()

            if let onUndo {
                undoButton(action: onUndo, hint: "Reverts this dose to not logged.")
            }
        }
    }

    /// "Snoozed 20 min · reminder at 10:20 AM" while the snooze runs, "Snoozed 20 min"
    /// once it has ended; Undo takes the last snooze back.
    private var snoozeFooter: some View {
        AdaptiveStack(spacing: Theme.Spacing.s2) {
            Label(snoozeText(time: times.time), systemImage: DoseStatus.snoozed.symbolName)
                .font(Theme.Font.text(.footnote))
                .foregroundStyle(Theme.Color.textSecondary)
                .accessibilityLabel(SnoozeWording.spoken(snoozeText(time: times.spokenTime)))

            Spacer()

            if let onUndo, dose.lastAction == .snoozed {
                undoButton(action: onUndo, hint: "Takes back the last snooze.")
            }
        }
    }

    private func snoozeText(time: (Date) -> String) -> String {
        var text = "Snoozed \(SnoozeWording.duration(minutes: dose.snoozeOffset))"
        if status == .snoozed, let until = dose.snoozedUntil {
            text += " · reminder at \(time(until))"
        }
        return text
    }

    private func undoButton(action: @escaping () -> Void, hint: String) -> some View {
        Button("Undo", action: action)
            .font(Theme.Font.text(.footnote).weight(.bold))
            .foregroundStyle(Theme.Color.accentStrong)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier(AccessibilityID.undoDoseButton(dose.id))
            .accessibilityHint(hint)
    }

    private var footerText: String {
        if status == .skipped {
            return "Skipped · \(times.time(dose.scheduledAt))"
        }
        if let completedAt = dose.completedAt {
            var text = "Logged at \(times.time(completedAt))"
            if dose.minutesLate > 0 {
                text += " · \(SnoozeWording.duration(minutes: dose.minutesLate)) late"
            }
            if dose.snoozeOffset > 0 {
                text += " · snoozed \(SnoozeWording.duration(minutes: dose.snoozeOffset))"
            }
            return text
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
        var parts = ["\(medicationName), \(status.title.lowercased()), \(spokenTimingText)."]
        if !isResolved, dose.snoozeOffset > 0 {
            parts.append("Snoozed \(SnoozeWording.duration(minutes: dose.snoozeOffset)) in all.")
        }
        if isActionable {
            parts.append(onSnooze == nil ? "Actions: Take, Skip." : "Actions: Take, Snooze, Skip.")
        } else if isResolved, onUndo != nil {
            parts.append("Double tap Undo to revert.")
        }
        return parts.joined(separator: " ")
    }
}
