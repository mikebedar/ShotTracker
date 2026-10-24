import Atelier
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
    @Environment(\.presenter) private var presenter

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
                        // Delete archives it (history stays) with Undo in the toast; red, and a full swipe
                        // never deletes (Atelier's rule for a destructive swipe on iOS).
                        .rowSwipeActions([
                            RowAction(id: "delete", verbatim: "Delete", systemImage: "trash", role: .destructive,
                                      identifier: AccessibilityID.deleteMedicationButton(medication.id)) {
                                MedicationArchiving.archive(medication, presenter: presenter, dependencies: dependencies,
                                                            context: modelContext)
                            },
                        ])
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
        }
    }
}

struct MedicationSummaryRow: View {
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

    /// Atelier's `ListRow`: the avatar leading, the text full width under it at AX1–AX5 (every line it needs).
    var body: some View {
        ListRow {
            Column(spacing: .xxs) {
                Text(medication.displayName)
                    .textRole(.subheading)
                    .auditsFit("medication.name")
                if let canonical = AppFormatting.medicationSubtitle(for: medication) {
                    Text(canonical)
                        .textRole(.doseTiming)
                        .auditsFit("medication.canonicalName")
                }
                if let nextDose {
                    let clockText = clockText(for: nextDose)
                    Text("\(statusText) • \(clockText.pointWithDate(nextDose.scheduledAt))")
                        .textRole(.doseTiming)
                        .auditsFit("medication.nextDose")
                    if let detail = clockText.detail(nextDose.scheduledAt) {
                        Text(detail)
                            .textRole(.doseDetail.colored(.secondary))
                    }
                } else {
                    Text("No upcoming doses")
                        .textRole(.doseTiming)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
        } leading: {
            MedicationArtworkView(medication: medication, size: 52)
        } trailing: {
            EmptyView()
        }
    }

    private var accessibilitySummary: String {
        let name = medication.spokenName
        if let nextDose {
            let status = dependencies.statusEvaluator.effectiveStatus(for: nextDose).title
            let time = "\(nextDose.scheduledAt.formatted(date: .abbreviated, time: .omitted)), \(clockText(for: nextDose).spokenPoint(nextDose.scheduledAt))"
            return "\(name). \(status). Next dose \(time)."
        }
        return "\(name). No upcoming doses."
    }

    /// "Oct 23, 2026 at 6:00 AM" at home; "Morning (Paris) · …" away (`DoseClockText`).
    private func clockText(for dose: ScheduledDose) -> DoseClockText {
        DoseClockText(dose: dose, medication: medication, dayParts: dependencies.preferencesStore.preferences.dayParts)
    }
}
