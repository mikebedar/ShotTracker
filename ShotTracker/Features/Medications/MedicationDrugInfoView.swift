import Atelier
import SwiftData
import SwiftUI

/// Full FDA structured-label sections for a medication, fetched via `DrugInfoService`
/// when the medication was added through Lookup. Boxed warning (the FDA's most
/// serious safety flag) is styled prominently; everything else is a plain scrollable
/// read.
struct MedicationDrugInfoView: View {
    @Environment(\.modelContext) private var modelContext
    let medication: Medication

    @State private var isRefreshing = false

    private var info: DrugLabelInfo? {
        medication.drugLabelInfo
    }

    var body: some View {
        List {
            if let boxedWarning = info?.boxedWarning, !boxedWarning.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Boxed Warning", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.Color.statusOverdue)
                        ForEach(Array(boxedWarning.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Rectangle().fill(Theme.Color.statusOverdueSoft))
            }

            labelSection(title: "Description", paragraphs: info?.drugDescription)
            labelSection(title: "Indications & Usage", paragraphs: info?.indicationsAndUsage)
            labelSection(title: "Warnings", paragraphs: info?.warnings)
            labelSection(title: "Adverse Reactions", paragraphs: info?.adverseReactions)

            Section {
                if let brandName = info?.brandName {
                    LabeledContent("Brand", value: brandName)
                }
                if let manufacturerName = info?.manufacturerName {
                    LabeledContent("Manufacturer", value: manufacturerName)
                }
                if let route = info?.route {
                    LabeledContent("Route", value: route)
                }
                if let fetchedAt = info?.fetchedAt {
                    LabeledContent("Last updated", value: fetchedAt.formatted(date: .abbreviated, time: .omitted))
                }
                Button {
                    Task { await refresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Text("Refresh")
                    }
                }
                .disabled(isRefreshing)
            }

            Section {
                Text("Source: FDA structured product labeling via openFDA. For informational purposes only — consult your doctor or pharmacist.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Drug Info")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func labelSection(title: String, paragraphs: [String]?) -> some View {
        if let paragraphs, !paragraphs.isEmpty {
            Section(title) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.subheadline)
                }
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let genericName = medication.canonicalName ?? medication.displayName
        if let updated = await DrugInfoService.fetchLabel(rxcui: medication.normalizedMedicationCode, genericName: genericName) {
            medication.drugLabelInfo = updated
            try? modelContext.save()
        }
    }
}
