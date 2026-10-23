import SwiftUI

/// A confirmed drug + exact strength/form, produced once a user finishes the
/// search → select-strength flow.
struct MedicationSelection: Equatable {
    let result: MedicationLookupResult
    let variant: MedicationVariant
}

/// Lookup-mode identity section: search list, or — once a variant is confirmed — a
/// compact summary card with a "Change" button back to search. Owns none of the save
/// logic; the parent observes `selection` to populate its draft and fetch drug info.
struct MedicationLookupIdentitySection: View {
    @Bindable var searchModel: MedicationSearchModel
    @Binding var selection: MedicationSelection?

    var body: some View {
        Section("Lookup") {
            if let selection {
                MedicationLookupConfirmedCard(selection: selection) {
                    self.selection = nil
                    searchModel.clear()
                }
            } else {
                TextField("Search medications", text: $searchModel.query)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier(AccessibilityID.searchField)

                if searchModel.isSearching {
                    ProgressView("Searching")
                }

                if let errorMessage = searchModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(searchModel.results) { result in
                    resultRow(for: result)
                }
            }
        }
        .task(id: searchModel.query) {
            await searchModel.search()
        }
    }

    @ViewBuilder
    private func resultRow(for result: MedicationLookupResult) -> some View {
        // A single-variant result has nothing to disambiguate, so confirm it directly
        // rather than pushing a picker screen with exactly one row.
        if result.variants.count <= 1 {
            Button {
                selection = MedicationSelection(
                    result: result,
                    variant: result.variants.first ?? MedicationVariant(strengthAndForm: "", rxcui: result.rxNormCode)
                )
            } label: {
                MedicationLookupResultRow(result: result)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.medicationLookupResultRow)
        } else {
            NavigationLink {
                MedicationVariantPickerView(result: result) { variant in
                    selection = MedicationSelection(result: result, variant: variant)
                }
            } label: {
                MedicationLookupResultRow(result: result)
            }
            .accessibilityIdentifier(AccessibilityID.medicationLookupResultRow)
        }
    }
}

private struct MedicationLookupResultRow: View {
    let result: MedicationLookupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.displayName)
                .foregroundStyle(.primary)
            if let routeSummary = result.routeSummary {
                Text(routeSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !result.variants.isEmpty {
                Text(result.variants.prefix(2).map(\.strengthAndForm).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MedicationLookupConfirmedCard: View {
    let selection: MedicationSelection
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.result.canonicalName)
                        .font(.headline)
                    if !selection.variant.strengthAndForm.isEmpty {
                        Text(selection.variant.strengthAndForm)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let routeSummary = selection.result.routeSummary {
                        Text(routeSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .accessibilityElement(children: .combine)

            Button("Change", action: onChange)
                .font(.footnote.weight(.semibold))
        }
    }
}

/// Pushed screen listing every strength/form for a drug+route search result.
private struct MedicationVariantPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let result: MedicationLookupResult
    let onSelect: (MedicationVariant) -> Void

    var body: some View {
        List(result.variants) { variant in
            Button {
                onSelect(variant)
                dismiss()
            } label: {
                Text(variant.strengthAndForm)
                    .foregroundStyle(.primary)
            }
            .accessibilityIdentifier(AccessibilityID.medicationLookupVariantRow)
        }
        .navigationTitle(result.canonicalName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Infers oral vs. injection from RxTerms' route text (e.g. "Oral Pill", "Injectable")
/// — the app's binary `MedicationKind` can't represent every route, so this is a
/// starting point the kind picker chips remain free to correct afterward.
func inferredMedicationKind(fromRouteSummary routeSummary: String?) -> MedicationKind {
    guard let routeSummary else { return .oral }
    return routeSummary.localizedCaseInsensitiveContains("inject") ? .injection : .oral
}
