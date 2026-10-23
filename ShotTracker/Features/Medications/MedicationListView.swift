import SwiftData
import SwiftUI

struct MedicationListView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Medication> { $0.isActive },
        sort: [SortDescriptor(\Medication.displayName)]
    ) private var medications: [Medication]
    @Query(filter: #Predicate<Medication> { !$0.isActive }) private var archivedMedications: [Medication]
    @State private var isPresentingAddMedication = false
    @State private var medicationPendingDeletion: Medication?

    var body: some View {
        NavigationStack {
            List {
                if medications.isEmpty {
                    ContentUnavailableView {
                        Label("Welcome to ShotTracker", systemImage: "pills.circle.fill")
                    } description: {
                        Text("Track your medications, get reminders when doses are due, and keep a history you can share with your doctor.")
                    } actions: {
                        Button {
                            isPresentingAddMedication = true
                        } label: {
                            Text("Add your first medication")
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ForEach(medications) { medication in
                        NavigationLink {
                            MedicationDetailView(medication: medication)
                        } label: {
                            MedicationSummaryRow(medication: medication)
                        }
                        .accessibilityIdentifier(AccessibilityID.medicationRow(medication.id))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                medicationPendingDeletion = medication
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .accessibilityIdentifier(AccessibilityID.deleteMedicationButton(medication.id))
                        }
                    }
                }

                if !archivedMedications.isEmpty {
                    Section {
                        NavigationLink {
                            ArchivedMedicationsView()
                        } label: {
                            Label("Archived (\(archivedMedications.count))", systemImage: "archivebox")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Medications")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingAddMedication = true
                    } label: {
                        Label("Add Medication", systemImage: "plus")
                    }
                    .accessibilityIdentifier(AccessibilityID.addMedicationButton)
                }
            }
            .sheet(isPresented: $isPresentingAddMedication) {
                NavigationStack {
                    EditMedicationView()
                }
            }
            .alert(
                "Delete \(medicationPendingDeletion?.displayName ?? "Medication")?",
                isPresented: Binding(
                    get: { medicationPendingDeletion != nil },
                    set: { isPresented in if !isPresented { medicationPendingDeletion = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    deletePendingMedication()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes it from your medications list and stops future doses. Its dose and refill history stay in History.")
            }
        }
    }

    private func deletePendingMedication() {
        guard let medication = medicationPendingDeletion else { return }
        medicationPendingDeletion = nil
        try? MedicationRepository.archive(medication, in: modelContext)
        dependencies.refreshSchedules(context: modelContext)
    }
}

private struct MedicationSummaryRow: View {
    @Environment(\.appDependencies) private var dependencies
    let medication: Medication

    private var nextDose: ScheduledDose? {
        let superseded = DoseSupersession.supersededIDs(for: medication, now: .now)
        return medication.scheduledDoses
            .filter {
                guard !superseded.contains($0.id) else { return false }
                let status = dependencies.statusEvaluator.effectiveStatus(for: $0)
                return status == .upcoming || status == .due || status == .overdue || status == .snoozed
            }
            .sorted(by: { $0.scheduledAt < $1.scheduledAt })
            .first
    }

    private var statusText: String {
        guard let nextDose else { return "No upcoming doses" }
        return dependencies.statusEvaluator.effectiveStatus(for: nextDose).title
    }

    var body: some View {
        AdaptiveStack(spacing: 12) {
            MedicationArtworkView(medication: medication, size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(medication.displayName)
                    .font(.headline)
                if let canonical = AppFormatting.medicationSubtitle(for: medication) {
                    Text(canonical)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let nextDose {
                    Text("\(statusText) • \(ZonedTimeFormatter(home: nextDose.homeTimeZone).dateTime(nextDose.scheduledAt))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No upcoming doses")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
        }
        .padding(.vertical, 4)
    }

    private var accessibilitySummary: String {
        let name = medication.spokenName
        if let nextDose {
            let status = dependencies.statusEvaluator.effectiveStatus(for: nextDose).title
            let times = ZonedTimeFormatter(home: nextDose.homeTimeZone)
            let time = "\(nextDose.scheduledAt.formatted(date: .abbreviated, time: .omitted)), \(times.spokenTime(nextDose.scheduledAt))"
            return "\(name). \(status). Next dose \(time)."
        }
        return "\(name). No upcoming doses."
    }
}
