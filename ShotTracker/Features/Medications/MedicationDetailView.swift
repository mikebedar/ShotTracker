import SwiftData
import SwiftUI

struct MedicationDetailView: View {
    @Environment(\.appDependencies) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let medication: Medication

    @State private var isPresentingEdit = false
    @State private var isPresentingRefill = false
    @State private var refillQuantityText = ""
    @State private var isPresentingDeleteConfirmation = false

    private var regimen: MedicationRegimen? {
        medication.regimens.active
    }

    private var supplyForecastText: String? {
        SupplyForecastService.projection(
            for: medication,
            engine: dependencies.scheduleEngine,
            preferences: dependencies.preferencesStore.preferences
        ).map(SupplyForecastService.summaryText)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        MedicationArtworkView(medication: medication)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(medication.displayName)
                                .font(.title3.weight(.semibold))
                            if let canonicalName = AppFormatting.medicationSubtitle(for: medication) {
                                Text(canonicalName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let selectedStrengthAndForm = medication.selectedStrengthAndForm {
                                Text(selectedStrengthAndForm)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let regimen {
                        Text(AppFormatting.scheduleText(for: regimen))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if medication.takeWithFood {
                        Label("Take with food", systemImage: "fork.knife")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !medication.notes.isEmpty {
                        Text(medication.notes)
                            .font(.body)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilitySummary)
            }

            if medication.isTrackingSupply, let unitLabel = medication.supplyUnitLabel {
                Section("Supply") {
                    SupplyRow(
                        currentContainerRemaining: medication.currentContainerRemaining,
                        unitsPerContainer: medication.unitsPerContainer ?? medication.totalRemaining,
                        totalRemaining: medication.totalRemaining,
                        unitLabel: unitLabel,
                        containerNoun: medication.kind.containerNoun,
                        isLow: medication.isSupplyLow,
                        forecastText: supplyForecastText
                    )
                    if let lastRefilledAt = medication.lastRefilledAt {
                        Text("Last refilled \(lastRefilledAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Log refill") {
                        refillQuantityText = String(medication.unitsPerContainer ?? 0)
                        isPresentingRefill = true
                    }
                }
            }

            Section {
                NavigationLink {
                    MedicationScheduledDosesView(medication: medication)
                } label: {
                    Label("Scheduled doses", systemImage: "calendar")
                }
                NavigationLink {
                    MedicationHistoryDetailView(medication: medication)
                } label: {
                    Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                if medication.drugLabelInfo?.hasContent == true {
                    NavigationLink {
                        MedicationDrugInfoView(medication: medication)
                    } label: {
                        Label("Drug Info", systemImage: "cross.case")
                    }
                }
            }

            Section {
                Button("Delete Medication", role: .destructive) {
                    isPresentingDeleteConfirmation = true
                }
                .accessibilityIdentifier(AccessibilityID.deleteMedicationButton)
            }
        }
        .navigationTitle("Details")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    isPresentingEdit = true
                }
            }
        }
        .sheet(isPresented: $isPresentingEdit) {
            NavigationStack {
                EditMedicationView(medication: medication)
            }
        }
        .alert("Log refill", isPresented: $isPresentingRefill) {
            TextField("Quantity", text: $refillQuantityText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Add") { logRefill() }
        } message: {
            Text("How many \(medication.supplyUnitLabel ?? "units") did you get? This adds a new \(medication.kind.containerNoun) to your supply.")
        }
        .alert("Delete \(medication.displayName)?", isPresented: $isPresentingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteMedication()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it from your medications list and stops future doses. Its dose and refill history stay in History.")
        }
    }

    private func logRefill() {
        guard let quantity = Int(refillQuantityText.trimmingCharacters(in: .whitespaces)), quantity > 0 else { return }
        try? MedicationRepository.logRefill(quantity, for: medication, in: modelContext)
    }

    private func deleteMedication() {
        try? MedicationRepository.archive(medication, in: modelContext)
        dependencies.refreshSchedules(context: modelContext)
        dismiss()
    }

    private var accessibilitySummary: String {
        var parts = [medication.spokenName]
        if let regimen {
            parts.append(AppFormatting.scheduleText(for: regimen))
        }
        if !medication.notes.isEmpty {
            parts.append(medication.notes)
        }
        return parts.joined(separator: ". ")
    }
}
