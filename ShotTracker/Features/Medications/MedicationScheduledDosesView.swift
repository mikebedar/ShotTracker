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
        medication.scheduledDoses
            .filter {
                let status = dependencies.statusEvaluator.effectiveStatus(for: $0)
                return status == .upcoming || status == .due || status == .overdue || status == .snoozed
            }
            .sorted { $0.scheduledAt < $1.scheduledAt }
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
                ForEach(upcomingDoses) { dose in
                    let status = dependencies.statusEvaluator.effectiveStatus(for: dose)
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(dose.timingLabel.replacingOccurrences(of: "-", with: " ").capitalized) • \(dose.scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.headline)
                            Text(status.title)
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

                        DoseActionBar(
                            doseID: dose.id,
                            status: status,
                            onTake: { takeDose(dose) },
                            onSnooze: { dependencies.recordDoseAction(.snoozed, dose: dose, context: modelContext) },
                            onSkip: { dependencies.recordDoseAction(.skipped, dose: dose, context: modelContext) }
                        )
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

    private func takeDose(_ dose: ScheduledDose) {
        if let regimen = medication.regimens.active,
           let warning = DoseRescheduling.minimumIntervalWarning(for: medication, regimen: regimen) {
            takeConfirmation = TakeConfirmation(dose: dose, message: warning.message)
        } else {
            dependencies.recordDoseAction(.taken, dose: dose, context: modelContext)
        }
    }
}
