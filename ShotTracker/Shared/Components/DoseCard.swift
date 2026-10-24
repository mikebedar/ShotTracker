import Atelier
import SwiftUI

/// Primary dose card: artwork + name + status badge, an action bar when actionable
/// (due/overdue), a "Logged"/Undo footer when resolved (taken/skipped), and an
/// optional supply row. Presentational only — callers own the `AppDependencies`
/// calls behind the action closures (and its swipe actions, `.rowSwipeActions`).
///
/// Built on Atelier: a raised `.surface` (tinted danger with a danger border when overdue),
/// `Badge` for the status, `AdaptiveStack(stacking: .atAccessibilitySizes)` for every row
/// that sits side by side, and `.auditsFit` on its text so `DoseCardFitTests` catches a
/// name cut short or pushed off a phone at AX5.
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
        Column(spacing: .m) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.l)
        .surface(isOverdue ? .tinted(.danger) : .raised, radius: .card)
        .overlay {
            if isOverdue {
                ctx.shape(.card).strokeBorder(.tone(.danger, .border), lineWidth: ctx.isIncreasedContrast ? 2 : 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @Environment(\.themeContext) private var ctx

    @ViewBuilder
    private var artwork: some View {
        if let medication {
            MedicationArtworkView(medication: medication)
        } else {
            ctx.shape(.control)
                .fill(.surfaceSubtle)
                .frame(width: ctx.iconSize(.large) * 2, height: ctx.iconSize(.large) * 2)
        }
    }

    private var badge: some View {
        Badge(verbatim: status.title, tone: status.tone)
    }

    private var header: some View {
        // Side by side up to xxxLarge; at AX1–AX5 the artwork and the badge share the first
        // line and the text runs full width below (beside them the fixed-size badge left the
        // name almost no room).
        AdaptiveStack(verticalAlignment: .top, spacing: .m, stacking: .atAccessibilitySizes) {
            if ctx.isAccessibilitySize {
                // On a 375 pt phone at AX5 "Upcoming" beside the artwork runs past the edge: then the
                // badge goes under it.
                AdaptiveStack(verticalAlignment: .top, spacing: .s) {
                    artwork
                    Spacer(minLength: ctx.space(.s))
                    badge
                }
            } else {
                artwork
            }
            details
                .frame(maxWidth: .infinity, alignment: .leading)
            if !ctx.isAccessibilitySize {
                badge
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
        Column(spacing: .xxs) {
            Text(medicationName)
                .textRole(.doseName)
                .auditsFit("dose.name")

            if let canonicalName {
                Text(canonicalName)
                    .textRole(.doseDetail)
                    .auditsFit("dose.canonicalName")
            }

            Label {
                Text(timingText).auditsFit("dose.timing")
            } icon: {
                Image(systemName: (medication?.kind ?? .oral).symbolName)
                    .textRole(.caption)
            }
            .textRole(.doseTiming)

            // Away from home, a slot's other clock: "Home: Night · by 6:00 AM".
            if let timingDetail {
                Text(timingDetail)
                    .textRole(.doseDetail)
                    .auditsFit("dose.timingDetail")
            }

            // "Keep at least N hours" held it back after a time zone change.
            if let heldText {
                Text(heldText)
                    .textRole(.doseDetail)
                    .auditsFit("dose.held")
                    .accessibilityIdentifier(AccessibilityID.heldDoseNote)
            }

            if medication?.takeWithFood == true {
                Label("Take with food", systemImage: "fork.knife")
                    .textRole(.doseDetail)
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

    /// "Opens 10:00 AM, 20 hours after your last dose" while a held dose hasn't opened.
    private var heldText: String? {
        guard let hours = dose.spacingHoldHours, status == .upcoming else { return nil }
        let opens = clockText.awaySlot?.time(dose.scheduledAt) ?? clockText.times.time(dose.scheduledAt)
        return String(localized: "Opens \(opens), \(hours) hours after your last dose", comment: "A dose held back by the minimum hours between doses")
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
        AdaptiveStack(spacing: .s, stacking: .atAccessibilitySizes) {
            Text(footerText)
                .textRole(.doseDetail)
                .auditsFit("dose.footer")

            Spacer()

            if let onUndo {
                undoButton(action: onUndo, hint: "Reverts this dose to not logged.")
            }
        }
    }

    /// "Snoozed 20 min · reminder at 10:20 AM" while the snooze runs, "Snoozed 20 min"
    /// once it has ended; Undo takes the last snooze back.
    private var snoozeFooter: some View {
        AdaptiveStack(spacing: .s, stacking: .atAccessibilitySizes) {
            Label(snoozeText(time: times.time), systemImage: DoseStatus.snoozed.symbolName)
                .textRole(.doseDetail.colored(.secondary))
                .auditsFit("dose.snooze")
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
            .textRole(.doseDetail.weighted(.bold).colored(.link))
            .minimumTouchTarget()
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

    private var accessibilityLabel: String {
        var parts = ["\(medicationName), \(status.title.lowercased()), \(spokenTimingText)."]
        if let heldText {
            parts.append(heldText + ".")
        }
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
