import SwiftData
import SwiftUI

/// Full scheduled/upcoming dose list for a single medication, with inline actions.
struct MedicationScheduledDosesView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext
    let medication: Medication

    @State private var takeConfirmation: TakeConfirmation?

    private struct TakeConfirmation: Identifiable {
        let id = UUID()
        let dose: ScheduledDose
        let message: String
    }

    private var upcomingDoses: [ScheduledDose] {
        let superseded = DoseSupersession.supersededIDs(for: medication, now: .now)
        return medication.scheduledDoses
            .filter {
                guard !superseded.contains($0.id) else { return false }
                let status = dependencies.statusEvaluator.effectiveStatus(for: $0)
                return status == .upcoming || status == .due || status == .overdue || status == .snoozed
            }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// Actions belong to what can be taken now — anything due/overdue/snoozed, plus the
    /// next upcoming dose (an early dose is allowed). The other ~90 days of the list are
    /// a preview; offering Take/Skip on a dose two months out invited mistakes.
    private func isActionable(_ dose: ScheduledDose, status: DoseStatus, firstUpcomingID: UUID?) -> Bool {
        status != .upcoming || dose.id == firstUpcomingID
    }

    var body: some View {
        List {
            if upcomingDoses.isEmpty {
                ContentUnavailableView(
                    "No scheduled doses",
                    systemImage: "calendar",
                    description: Text("Upcoming doses for this medication will appear here.")
                )
            } else {
                let firstUpcomingID = upcomingDoses.first {
                    dependencies.statusEvaluator.effectiveStatus(for: $0) == .upcoming
                }?.id
                ForEach(upcomingDoses) { dose in
                    let status = dependencies.statusEvaluator.effectiveStatus(for: dose)
                    let clockText = DoseClockText(dose: dose, medication: medication, dayParts: dependencies.preferencesStore.preferences.dayParts)
                    let times = clockText.times
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let slot = clockText.awaySlot {
                                // "Morning (Paris) • Oct 23, 2026 at 6:00 AM" + "Home: Night · 12:00 AM"
                                Text("\(slot.title) • \(slot.dateTime(dose.scheduledAt))")
                                    .font(.headline)
                                    .accessibilityLabel("\(dose.scheduledAt.formatted(date: .abbreviated, time: .omitted)), \(clockText.spokenPoint(dose.scheduledAt))")
                                if let detail = slot.detail(dose.scheduledAt) {
                                    Text(detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            } else {
                                Text("\(dose.slotTitle) • \(times.dateTime(dose.scheduledAt))")
                                    .font(.headline)
                                    .accessibilityLabel("\(dose.slotTitle), \(dose.scheduledAt.formatted(date: .abbreviated, time: .omitted)), \(times.spokenTime(dose.scheduledAt))")
                            }
                            Text(statusLine(for: dose, status: status, times: times))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        // Row-level identifier lives on this inner, non-interactive group
                        // rather than the outer VStack: a container that also encloses
                        // DoseActionBar's buttons overrides those buttons' own identifiers
                        // in the XCUITest accessibility tree (verified via a live
                        // accessibility-hierarchy dump).
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(AccessibilityID.scheduledDoseRow(dose.id))

                        if isActionable(dose, status: status, firstUpcomingID: firstUpcomingID) {
                            DoseActionBar(
                                doseID: dose.id,
                                status: status,
                                onTake: { takeDose(dose) },
                                onSnooze: DoseActions.canSnooze(dose, status: status)
                                    ? { dependencies.recordDoseAction(.snoozed, dose: dose, context: modelContext) }
                                    : nil,
                                onSkip: { dependencies.recordDoseAction(.skipped, dose: dose, context: modelContext) }
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle("Scheduled")
        .alert(
            "Take dose early?",
            isPresented: Binding(
                get: { takeConfirmation != nil },
                set: { if !$0 { takeConfirmation = nil } }
            ),
            presenting: takeConfirmation
        ) { confirmation in
            Button("Take Anyway") { dependencies.recordDoseAction(.taken, dose: confirmation.dose, context: modelContext) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// "Due", or with a snooze "Snoozed 20 min · reminder at 10:20 AM" / "Due · snoozed
    /// 20 min, take by 12:20 PM".
    private func statusLine(for dose: ScheduledDose, status: DoseStatus, times: ZonedTimeFormatter) -> String {
        guard dose.snoozeOffset > 0 else { return status.title }
        let snoozed = SnoozeWording.duration(minutes: dose.snoozeOffset)
        if status == .snoozed, let until = dose.snoozedUntil {
            return "Snoozed \(snoozed) · reminder at \(times.time(until))"
        }
        return "\(status.title) · snoozed \(snoozed), take by \(times.time(dose.deadline))"
    }

    private func takeDose(_ dose: ScheduledDose) {
        if let regimen = medication.regimens.active,
           let warning = DoseRescheduling.minimumIntervalWarning(for: medication, regimen: regimen) {
            takeConfirmation = TakeConfirmation(dose: dose, message: warning.message)
        } else {
            dependencies.recordDoseAction(.taken, dose: dose, context: modelContext)
        }
    }
}
