import SwiftData
import SwiftUI

/// Archived ("deleted") medications — hidden from the active list and scheduling, but
/// with all history preserved. Reactivating puts one back into rotation and rebuilds its
/// upcoming doses.
struct ArchivedMedicationsView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Medication> { !$0.isActive },
        sort: [SortDescriptor(\Medication.displayName)]
    ) private var archivedMedications: [Medication]

    var body: some View {
        List {
            if archivedMedications.isEmpty {
                ContentUnavailableView(
                    "No archived medications",
                    systemImage: "archivebox",
                    description: Text("Medications you delete are kept here with their history intact.")
                )
            } else {
                ForEach(archivedMedications) { medication in
                    AdaptiveStack(spacing: 12) {
                        MedicationArtworkView(medication: medication, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(medication.displayName)
                                .font(.headline)
                            if let canonical = AppFormatting.medicationSubtitle(for: medication) {
                                Text(canonical)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Reactivate") {
                            reactivate(medication)
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Archived")
    }

    private func reactivate(_ medication: Medication) {
        try? MedicationRepository.unarchive(medication, in: modelContext)
        dependencies.refreshSchedules(context: modelContext)
    }
}
